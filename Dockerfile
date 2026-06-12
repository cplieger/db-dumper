# check=error=true

# renovate: datasource=docker depName=golang
FROM golang:1.26-alpine@sha256:7a3e50096189ad57c9f9f865e7e4aa8585ed1585248513dc5cda498e2f41812c AS builder


WORKDIR /src
COPY go.mod ./
RUN go mod download
COPY cmd/ cmd/
RUN CGO_ENABLED=0 \
    go build -trimpath -ldflags="-s -w" -o /cgiserver ./cmd/cgiserver

# Use alpine + docker-cli (just /usr/bin/docker, no buildx/compose plugins) instead
# of the official `docker:29-cli` image. Eliminates ~150 MB and 15 plugin CVEs;
# we only call `docker version|exec|inspect` so the plugins are dead weight.
# renovate: datasource=docker depName=alpine
FROM alpine:3.24@sha256:a2d49ea686c2adfe3c992e47dc3b5e7fa6e6b5055609400dc2acaeb241c829f4

# docker-cli for talking to the host docker.sock (mounted by compose);
# wget for the HEALTHCHECK below (busybox in alpine already provides it, but
# we also pull tini for clean signal handling under PID 1).
RUN apk add --no-cache docker-cli tini

COPY --from=builder /cgiserver /usr/local/bin/cgiserver

COPY --chmod=755 lib/validate.sh /usr/local/lib/validate.sh
COPY --chmod=755 lib/log.sh /usr/local/lib/log.sh
COPY --chmod=755 lib/http.sh /usr/local/lib/http.sh
COPY --chmod=755 dump.sh /srv/cgi-bin/dump
COPY --chmod=755 health.sh /srv/cgi-bin/health
COPY --chmod=755 entrypoint.sh /usr/local/bin/entrypoint

EXPOSE 9847
HEALTHCHECK --interval=30s --timeout=5s --retries=3 --start-period=15s \
    CMD body=$(wget -qO - http://127.0.0.1:9847/cgi-bin/health 2>&1) || { printf '%s\n' "$body" >&2; exit 1; }; \
        case "$body" in ok*) exit 0 ;; *) printf '%s\n' "$body" >&2; exit 1 ;; esac
ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/entrypoint"]
