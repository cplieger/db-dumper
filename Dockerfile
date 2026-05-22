# check=error=true

# renovate: datasource=docker depName=docker
FROM docker:29-cli@sha256:9ba8e32bfc35a2c7ae2feb1e3241b2778ae21dee80f4dcd31d04e1cfdea86ea2

# busybox-extras provides httpd for CGI; no minimal alternative on Alpine.
# Version pinning not supported: busybox-extras is a sub-package of busybox
# whose version is locked to the base image's busybox release (no independent
# version in the Alpine package index).
# Side-effect: also installs ftpd, telnetd, dnsd, inetd (unused).
RUN apk add --no-cache busybox-extras  # httpd for CGI

COPY --chmod=755 lib/validate.sh /usr/local/lib/validate.sh
COPY --chmod=755 lib/log.sh /usr/local/lib/log.sh
COPY --chmod=755 lib/http.sh /usr/local/lib/http.sh
COPY --chmod=755 dump.sh /srv/cgi-bin/dump
COPY --chmod=755 health.sh /srv/cgi-bin/health
COPY --chmod=755 entrypoint.sh /usr/local/bin/entrypoint

EXPOSE 9847
# CGI health probe. Captures the body so `docker inspect ... Health.Log`
# shows the failure reason (e.g. "unhealthy: DB_SPECS_empty docker_unreachable")
# instead of an empty Output with ExitCode 1.
HEALTHCHECK --interval=30s --timeout=5s --retries=3 --start-period=15s \
    CMD body=$(wget -qO - http://127.0.0.1:9847/cgi-bin/health 2>&1) || { printf '%s\n' "$body" >&2; exit 1; }; \
        case "$body" in ok*) exit 0 ;; *) printf '%s\n' "$body" >&2; exit 1 ;; esac
ENTRYPOINT ["/usr/local/bin/entrypoint"]
