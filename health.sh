#!/bin/sh
# CGI health endpoint: probe the preconditions a real dump request needs,
# not just HTTP liveness. Always returns HTTP 200 — healthy vs unhealthy
# is encoded in the first word of the body (`ok` or `unhealthy:`).
#
# Rationale: busybox wget in docker:29-cli discards response bodies on
# 4xx/5xx status codes ("wget: server returned error: HTTP/1.0 503 ..."
# to stderr, nothing to stdout). The Docker healthcheck in compose.yaml
# relies on the body to surface the reason (DB_SPECS_empty /
# DUMP_DIR_not_writable / docker_unreachable) in `docker inspect`, so
# the CGI must stay on HTTP 200 even when degraded. Do not "fix" this
# back to 503 — it will silently break the cycle-4 observability work.

# shellcheck source-path=SCRIPTDIR source=lib/log.sh
. /usr/local/lib/log.sh
# shellcheck source-path=SCRIPTDIR source=lib/http.sh
. /usr/local/lib/http.sh

DUMP_DIR="${DUMP_DIR:-/dumps}"
problems=""

[ -z "${DB_SPECS:-}" ] && problems="$problems DB_SPECS_empty"
[ -w "$DUMP_DIR" ] || problems="$problems DUMP_DIR_not_writable"
docker version > /dev/null 2>&1 || problems="$problems docker_unreachable"

printf 'Content-Type: text/plain\r\n\r\n'
if [ -n "$problems" ]; then
  log_warn "health check degraded" "problems=$problems"
  printf 'unhealthy:%s\n' "$problems"
else
  printf 'ok\n'
fi
