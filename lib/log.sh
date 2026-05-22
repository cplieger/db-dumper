#!/bin/sh
# Structured log helpers for db-dumper scripts.
# Output format matches Loki/Grafana structured log expectations.

# log_info: emit an info-level structured log line to stderr.
# Usage: log_info "msg text" [key=value ...]
log_info() {
  _msg="$1"
  shift
  printf 'level=info msg="%s"' "$_msg" >&2
  for _kv in "$@"; do printf ' %s' "$_kv" >&2; done
  printf '\n' >&2
}

# log_warn: emit a warn-level structured log line to stderr.
# Usage: log_warn "msg text" [key=value ...]
log_warn() {
  _msg="$1"
  shift
  printf 'level=warn msg="%s"' "$_msg" >&2
  for _kv in "$@"; do printf ' %s' "$_kv" >&2; done
  printf '\n' >&2
}

# log_error: emit an error-level structured log line to stderr.
# Usage: log_error "msg text" [key=value ...]
log_error() {
  _msg="$1"
  shift
  printf 'level=error msg="%s"' "$_msg" >&2
  for _kv in "$@"; do printf ' %s' "$_kv" >&2; done
  printf '\n' >&2
}
