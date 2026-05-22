#!/bin/sh
# db-dumper entrypoint: clean up stale tmp files from previous container
# lifetimes, then exec cgiserver in background, then wait.
#
# Stale cleanup is safe here because no CGI children exist yet — any
# *.dump.tmp.* file found at start-up was orphaned by a crash, OOM kill,
# or SIGKILL on container stop.
set -eu

# shellcheck source-path=SCRIPTDIR source=lib/log.sh
. /usr/local/lib/log.sh
# shellcheck source-path=SCRIPTDIR source=lib/validate.sh
. /usr/local/lib/validate.sh

DUMP_DIR="${DUMP_DIR:-/dumps}"

if [ -d "$DUMP_DIR" ]; then
  find "$DUMP_DIR" -maxdepth 1 -name '*.dump.tmp.*' \
    -type f -delete 2> /dev/null || true
fi

# Warn (don't delete) on ${dbname}.dump files whose dbname is not currently
# configured in DB_SPECS. Kopia would otherwise keep snapshotting the orphan
# forever with an unchanged mtime; the warning gives operators a chance to
# reconcile without the risk of a misconfigured DB_SPECS wiping real backups.
warn_orphan_dumps() {
  [ -d "$DUMP_DIR" ] || return 0

  _known_dbnames=""
  for _spec in $DB_SPECS; do
    _remainder="${_spec#*:}"
    _known_dbnames="$_known_dbnames ${_remainder%%:*}"
  done

  for _f in "$DUMP_DIR"/*.dump; do
    [ -e "$_f" ] || continue
    _base="${_f##*/}"
    _base="${_base%.dump}"
    case " $_known_dbnames " in
      *" $_base "*) continue ;;
    esac

    _mtime=$(stat -c%Y "$_f" 2> /dev/null || printf '')
    if [ -n "$_mtime" ]; then
      _age_hours=$((($(date +%s) - _mtime) / 3600))
      log_warn "orphan dump file (not in DB_SPECS)" "file=$_base" "age_hours=$_age_hours"
    else
      log_warn "orphan dump file (not in DB_SPECS)" "file=$_base" "age_hours=unknown"
    fi
  done
}

if [ -z "${DB_SPECS:-}" ]; then
  log_warn "DB_SPECS is empty — CGI requests will fail until configured" "dump_dir=$DUMP_DIR"
else
  # Mirror the per-request control-char guard at startup so deploy-time
  # misconfig (stray tab, newline) is surfaced before the first cron
  # firing. Warn-only — the CGI layer will still reject the request.
  if ! validate_no_control_chars "DB_SPECS" "$DB_SPECS" 2> /dev/null; then
    log_warn "DB_SPECS contains control characters; CGI will reject all requests"
  fi

  # Mirror dump.sh numeric validation of DUMP_TIMEOUT / DUMP_FREE_KB_WARN
  # so typos (DB_DUMPER_TIMEOUT=500s, DB_DUMPER_FREE_KB_WARN=1g) are
  # visible at deploy time, not at 02:00 the next morning. Warn-only —
  # dump.sh falls back to its own defaults on invalid values.
  _timeout="${DUMP_TIMEOUT:-300}"
  if ! validate_numeric "DUMP_TIMEOUT" "$_timeout" 2> /dev/null; then
    log_warn "DUMP_TIMEOUT is not a positive integer; dump.sh will fall back to default" "value=$_timeout"
  elif [ "$_timeout" -lt 10 ]; then
    log_warn "DUMP_TIMEOUT <10s; dump.sh will fall back to default" "value=$_timeout"
  fi
  _free_kb="${DUMP_FREE_KB_WARN:-1048576}"
  if ! validate_numeric "DUMP_FREE_KB_WARN" "$_free_kb" 2> /dev/null; then
    log_warn "DUMP_FREE_KB_WARN is not a non-negative integer; dump.sh will fall back to default" "value=$_free_kb"
  fi

  # Count parseable specs (exactly two colons) only, so the startup
  # `db_count` field matches what the CGI path will actually dump.
  _count=0
  for _spec in $DB_SPECS; do
    _colons=$(printf '%s' "$_spec" | tr -cd ':')
    [ "${#_colons}" -eq 2 ] && _count=$((_count + 1))
  done
  log_info "db-dumper ready" "dump_dir=$DUMP_DIR" "db_count=$_count"

  warn_orphan_dumps
fi

cleanup() {
  # Propagate signal to cgiserver child for graceful shutdown.
  [ -n "${HTTPD_PID:-}" ] && kill "$HTTPD_PID" 2> /dev/null
}
trap cleanup INT TERM

cgiserver &
HTTPD_PID=$!
wait "$HTTPD_PID"
