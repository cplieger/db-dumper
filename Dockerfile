# check=error=true

# renovate: datasource=docker depName=golang
FROM --platform=$BUILDPLATFORM golang:1.26-alpine@sha256:f23e8b227fb4493eabe03bede4d5a32d04092da71962f1fb79b5f7d1e6c2a17f AS builder

ARG TARGETARCH
ARG TARGETOS=linux

WORKDIR /src
COPY go.mod ./
RUN go mod download
COPY cmd/ cmd/
RUN CGO_ENABLED=0 GOOS=${TARGETOS} GOARCH=${TARGETARCH} \
    go build -trimpath -ldflags="-s -w" -o /cgiserver ./cmd/cgiserver

# Use alpine + docker-cli (just /usr/bin/docker, no buildx/compose plugins) instead
# of the official `docker:29-cli` image. Eliminates ~150 MB and 15 plugin CVEs;
# we only call `docker version|exec|inspect` so the plugins are dead weight.
# renovate: datasource=docker depName=alpine
FROM alpine:3.23@sha256:5b10f432ef3da1b8d4c7eb6c487f2f5a8f096bc91145e68878dd4a5019afde11

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
