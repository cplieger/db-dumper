#!/bin/sh
# shellcheck disable=SC3043  # local is supported by busybox ash (Alpine /bin/sh)
# CGI endpoint: runs pg_dump for all databases in DB_SPECS.
# Returns per-database status with sizes on success, errors on failure.
# Also logs to stderr (Docker logs) for Loki/Grafana visibility.
#
# Environment:
#   DB_SPECS              — space-separated container:dbname:user tuples.
#   DUMP_DIR              — output directory (default /dumps).
#   DUMP_TIMEOUT          — per-dump timeout in seconds (default 300, min 10).
#   DUMP_FREE_KB_WARN     — low-disk warning threshold in KB (default 1048576 = 1 GiB).

# Restrict dump file permissions to owner-only (0600).
umask 0077

DEFAULT_DUMP_TIMEOUT=300
DEFAULT_FREE_KB_WARN=1048576
LOCK_FILE="/tmp/db-dumper.lock"

DUMP_DIR="${DUMP_DIR:-/dumps}"
: "${DUMP_TIMEOUT:=$DEFAULT_DUMP_TIMEOUT}"
: "${DUMP_FREE_KB_WARN:=$DEFAULT_FREE_KB_WARN}"

# --- Shared libraries ---
# shellcheck source-path=SCRIPTDIR source=lib/log.sh
. /usr/local/lib/log.sh
# shellcheck source-path=SCRIPTDIR source=lib/http.sh
. /usr/local/lib/http.sh
# shellcheck source-path=SCRIPTDIR source=lib/validate.sh
. /usr/local/lib/validate.sh

# Files this CGI invocation owns; cleanup only rms these (not a glob) so
# concurrent invocations don't clobber each other's in-flight dumps.
my_tmp_files=""
err_file=""

cleanup() {
  [ -n "${err_file:-}" ] && rm -f "$err_file"
  for _f in ${my_tmp_files:-}; do rm -f "$_f"; done
}
trap cleanup EXIT INT TERM

# --- Functions ---

# record_ok: record a successful dump result.
# Usage: record_ok <dbname> <detail>
record_ok() {
  db_results="${db_results}${1}: ${2}
"
  ok_count=$((ok_count + 1))
}

# record_fail: record a failed dump result.
# Usage: record_fail <label> <detail>
record_fail() {
  db_errors="${db_errors}${1}: ${2}
"
  fail_count=$((fail_count + 1))
}

# validate_environment: validate all env vars and preconditions, exit on fatal errors.
validate_environment() {
  # Reject empty or path-traversal DUMP_DIR before it's used in any glob.
  case "$DUMP_DIR" in
    "")
      log_error "DUMP_DIR is empty"
      respond_error "500 Internal Server Error" "DUMP_DIR is empty"
      ;;
    *".."*)
      log_error "DUMP_DIR contains path traversal"
      respond_error "500 Internal Server Error" "DUMP_DIR contains path traversal"
      ;;
  esac

  if ! mkdir -p "$DUMP_DIR" 2> /dev/null; then
    log_error "cannot create dump directory" "dir=$DUMP_DIR"
    respond_error "500 Internal Server Error" "cannot create dump directory"
  fi

  if [ -z "$DB_SPECS" ]; then
    log_error "DB_SPECS is empty — no databases configured"
    respond_error "500 Internal Server Error" "DB_SPECS is empty — no databases configured"
  fi

  # Reject control chars in DB_SPECS so log-forging via embedded \n is impossible
  # even before per-identifier validation runs (bad-spec error lines echo the
  # raw spec value).
  if ! validate_no_control_chars "DB_SPECS" "$DB_SPECS"; then
    respond_error "500 Internal Server Error" "DB_SPECS contains control characters"
  fi

  # Validate DUMP_TIMEOUT is numeric and at least 10s; fall back to default
  # on bad input or values too small to be useful (`timeout 0 ...` terminates
  # immediately, making every dump fail with an empty-stderr error).
  if ! validate_numeric "DUMP_TIMEOUT" "$DUMP_TIMEOUT" 2> /dev/null ||
    [ "$DUMP_TIMEOUT" -lt 10 ]; then
    log_warn "DUMP_TIMEOUT invalid or <10s, using $DEFAULT_DUMP_TIMEOUT" "value=$DUMP_TIMEOUT"
    DUMP_TIMEOUT=$DEFAULT_DUMP_TIMEOUT
  fi

  # Validate DUMP_FREE_KB_WARN is numeric; fall back to default on bad input.
  # A non-numeric value would cause a shell error on the -lt comparison below
  # and silently disable the low-disk warning.
  if ! validate_numeric "DUMP_FREE_KB_WARN" "$DUMP_FREE_KB_WARN" 2> /dev/null; then
    log_warn "DUMP_FREE_KB_WARN invalid, using $DEFAULT_FREE_KB_WARN" "value=$DUMP_FREE_KB_WARN"
    DUMP_FREE_KB_WARN=$DEFAULT_FREE_KB_WARN
  fi

  # Grace period before SIGKILL when the SIGTERM deadline fires. busybox
  # `timeout` without `-k` would only send SIGTERM; a TERM-ignoring process
  # would keep running. Cap between 10s and 60s so large dumps still get
  # a reasonable shutdown window without unbounded wait.
  TIMEOUT_KILL=$((DUMP_TIMEOUT / 10))
  [ "$TIMEOUT_KILL" -lt 10 ] && TIMEOUT_KILL=10
  [ "$TIMEOUT_KILL" -gt 60 ] && TIMEOUT_KILL=60

  # Fail early if Docker daemon is unreachable (request-time liveness of the
  # exec path; healthcheck only covers HTTP liveness).
  if ! docker version > /dev/null 2>&1; then
    log_error "Docker daemon unreachable"
    respond_error "503 Service Unavailable" "Docker daemon unreachable"
  fi
}

# check_disk_space: warn when dump volume is running low.
check_disk_space() {
  local avail
  avail=$(df -P "$DUMP_DIR" 2> /dev/null | awk 'NR==2 {print $4}')
  case "$avail" in
    '' | *[!0-9]*)
      log_warn "cannot parse df output" "dir=$DUMP_DIR" "avail=$avail"
      ;;
    *)
      if [ "$avail" -lt "$DUMP_FREE_KB_WARN" ]; then
        log_warn "low disk space on dump volume" "avail_kb=$avail" "threshold_kb=$DUMP_FREE_KB_WARN"
      fi
      ;;
  esac
}

# validate_dump_spec: parse and validate a single spec entry.
# Usage: validate_dump_spec <spec>
# Sets globals: container, dbname, user
# Returns 0 on success, 1 on validation failure (records the error).
validate_dump_spec() {
  local spec remainder first_container
  spec="$1"

  if ! validate_spec_format "$spec"; then
    record_fail "$spec" "invalid format (expected container:dbname:user)"
    return 1
  fi

  container="${spec%%:*}"
  remainder="${spec#*:}"
  dbname="${remainder%%:*}"
  user="${remainder#*:}"

  if ! validate_identifier "container" "$container"; then
    record_fail "$spec" "invalid container"
    return 1
  fi
  if ! validate_identifier "dbname" "$dbname"; then
    record_fail "$spec" "invalid dbname"
    return 1
  fi
  if ! validate_identifier "user" "$user"; then
    record_fail "$spec" "invalid user"
    return 1
  fi

  # Duplicate-dbname detection: the loop would otherwise silently overwrite
  # one dump with another (e.g. pg1:app:u pg2:app:u in a multi-host setup).
  # Checked after validation so malformed earlier specs can't mask a later
  # real duplicate. Report the container of the first (winning) spec so
  # operators know which one was kept and which one was silently skipped.
  case " $seen_dbnames " in
    *" $dbname "*)
      first_container="unknown"
      for _pair in $seen_pairs; do
        case "$_pair" in
          "$dbname":*)
            first_container="${_pair#*:}"
            break
            ;;
        esac
      done
      record_fail "$dbname" "duplicate dbname in DB_SPECS (kept first)"
      log_error "duplicate dbname in DB_SPECS; only first spec was dumped" "db=$dbname" "container=$container" "first_container=$first_container"
      return 1
      ;;
  esac
  seen_dbnames="$seen_dbnames $dbname"
  seen_pairs="$seen_pairs $dbname:$container"
  return 0
}

# execute_dump: run pg_dump for a validated spec.
# Usage: execute_dump
# Reads globals: container, dbname, user, DUMP_DIR, TIMEOUT_KILL, DUMP_TIMEOUT
# Sets globals: tmpfile, err_file, rc, duration, my_tmp_files
# Returns 0 if dump command ran (check rc for result), 1 if setup failed.
execute_dump() {
  local spec_start
  outfile="${DUMP_DIR}/${dbname}.dump"
  # mktemp in DUMP_DIR so the final mv is an atomic same-filesystem rename.
  tmpfile=$(mktemp "${DUMP_DIR}/${dbname}.dump.tmp.XXXXXX") || {
    log_error "cannot create temp file" "db=$dbname"
    record_fail "$dbname" "cannot create temp file"
    return 1
  }
  my_tmp_files="$my_tmp_files $tmpfile"

  err_file=$(mktemp) || {
    log_error "cannot create err file" "db=$dbname"
    record_fail "$dbname" "cannot create err file"
    rm -f "$tmpfile"
    return 1
  }

  printf 'level=debug db=%s msg="starting dump" container=%s user=%s\n' \
    "$dbname" "$container" "$user" >&2

  spec_start=$(date +%s)
  # `--` terminates pg_dump flag parsing so identifiers starting with `-`
  # (already rejected above, defense-in-depth) can't be interpreted as flags.
  # `-k TIMEOUT_KILL` escalates SIGTERM to SIGKILL if pg_dump ignores the
  # soft deadline (stuck in kernel I/O, holding fs lock, non-interruptible
  # system call).
  timeout -k "$TIMEOUT_KILL" "$DUMP_TIMEOUT" docker exec "$container" pg_dump \
    --format=custom --username="$user" -- "$dbname" \
    > "$tmpfile" 2> "$err_file"
  rc=$?
  duration=$(($(date +%s) - spec_start))
  return 0
}

# classify_result: classify the dump exit code and handle success/failure.
# Usage: classify_result
# Reads globals: rc, tmpfile, err_file, dbname, container, user, duration, DUMP_DIR
# Updates globals: ok_count, fail_count, db_results, db_errors
classify_result() {
  local reason size raw_err err
  # Classify the exit code so Grafana panels can key on a single field
  # instead of free-text substring matches on `err=...`.
  case "$rc" in
    0) reason=ok ;;
    124) reason=timeout ;;
    137) reason=killed ;;
    1) reason=pg_error ;;
    125 | 126 | 127) reason=docker_error ;;
    *) reason=other ;;
  esac

  if [ "$rc" -eq 0 ]; then
    size=$(stat -c%s "$tmpfile" 2> /dev/null || printf '0')
    if [ "$size" = "0" ]; then
      record_fail "$dbname" "dump succeeded but file is empty"
      log_error "dump succeeded but file is empty" "db=$dbname" "container=$container" "reason=empty" "duration_s=$duration"
      rm -f "$tmpfile"
    elif ! docker exec -i "$container" pg_restore --list < "$tmpfile" > /dev/null 2>&1; then
      record_fail "$dbname" "dump appears truncated (TOC unreadable)"
      log_error "dump appears truncated" "db=$dbname" "container=$container" "reason=truncated" "size=$size" "duration_s=$duration"
      rm -f "$tmpfile"
    else
      mv "$tmpfile" "$outfile"
      record_ok "$dbname" "ok (${size} bytes)"
      log_info "dump ok" "db=$dbname" "container=$container" "reason=$reason" "size=$size" "duration_s=$duration"
    fi
  else
    # Collapse multi-line pg_dump errors to a single line and escape
    # double-quotes so the structured log line stays parseable.
    raw_err=$(tr '\n' ' ' < "$err_file" | sed 's/"/\\"/g')
    err=$(printf '%.200s' "$raw_err")
    [ "${#raw_err}" -gt 200 ] && err="${err}...[truncated]"
    [ -z "$err" ] && err="(no stderr; rc=$rc)"

    # On timeout (124) or kill (137), the pg_dump backend inside the
    # target container may still be running — docker exec does not
    # propagate signals to the remote process. Alert the operator so
    # the next cron firing doesn't queue behind a zombie backend.
    if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
      log_warn "pg_dump client killed; attempting to terminate orphan backend" "db=$dbname" "container=$container" "reason=$reason"
      # Kill any pg_dump processes inside the target container to prevent
      # lock contention on the next cron firing. Best-effort: if the
      # container is unreachable the next dump will fail with docker_error.
      docker exec "$container" pkill -f "pg_dump.*--username=$user.*$dbname" 2> /dev/null || true
    fi

    record_fail "$dbname" "dump failed (${reason})"
    log_error "dump failed" "db=$dbname" "container=$container" "reason=$reason" "duration_s=$duration" "err=$err"
    rm -f "$tmpfile"
  fi
  rm -f "$err_file"
  err_file=""
}

# dump_single_db: run pg_dump for one spec entry.
# Usage: dump_single_db <spec>
# Updates global: ok_count, fail_count, errors, results, seen_dbnames, seen_pairs, my_tmp_files, err_file
dump_single_db() {
  validate_dump_spec "$1" || return
  execute_dump || return
  classify_result
}

# emit_summary_response: log summary and emit HTTP response.
emit_summary_response() {
  local total_duration summary_level body
  total_duration=$(($(date +%s) - run_start))
  if [ "$fail_count" -gt 0 ] && [ "$ok_count" -eq 0 ]; then
    summary_level=error
  elif [ "$fail_count" -gt 0 ]; then
    summary_level=warn
  else
    summary_level=info
  fi
  case "$summary_level" in
    info) log_info "dump complete" "ok=$ok_count" "failed=$fail_count" "duration_s=$total_duration" ;;
    warn) log_warn "dump complete" "ok=$ok_count" "failed=$fail_count" "duration_s=$total_duration" ;;
    error) log_error "dump complete" "ok=$ok_count" "failed=$fail_count" "duration_s=$total_duration" ;;
  esac

  body="${db_results}${db_errors}"
  if [ -n "$db_errors" ]; then
    respond "500 Internal Server Error" "text/plain" "$body"
  else
    respond "" "text/plain" "$body"
  fi
}

# --- Request method check (reject HEAD, DELETE, etc.) ---

case "${REQUEST_METHOD:-GET}" in
  GET | POST) ;;
  *)
    log_warn "method not allowed" "method=${REQUEST_METHOD:-unknown}" "remote=${REMOTE_ADDR:-unknown}"
    respond "405 Method Not Allowed" "text/plain" "Method not allowed
"
    exit 0
    ;;
esac

# --- Concurrency guard ---
#
# The CGI server forks a fresh child per request. Without this top-level
# lock, two concurrent dumps would hammer the source DB twice (e.g. a
# manual trigger arriving during a scheduled run, or an accidental curl
# loop). Reject with 429 so the caller's retry policy decides what to do.
# The lock is released when the CGI child exits.
exec 9> "$LOCK_FILE"
if ! flock -n 9; then
  log_warn "dump already in progress, rejecting concurrent request" "remote=${REMOTE_ADDR:-unknown}"
  respond "429 Too Many Requests" "text/plain" "dump already in progress
"
  exit 0
fi

# --- Input validation ---
validate_environment

# --- Disk space check ---
check_disk_space

# --- Dump loop ---

ok_count=0
fail_count=0
db_results=""
db_errors=""
seen_dbnames=""
# Parallel list of "dbname:first_container" pairs so a duplicate report
# can point the operator at the winning spec without a second pass.
seen_pairs=""

# Log request receipt with database count.
spec_count=0
for _ in $DB_SPECS; do spec_count=$((spec_count + 1)); done
log_info "dump request received" "databases=$spec_count"

run_start=$(date +%s)

# Word-splitting on $DB_SPECS is intentional (space-separated specs).
for spec in $DB_SPECS; do
  dump_single_db "$spec"
done

# --- Summary and response ---
emit_summary_response
