# check=error=true

# renovate: datasource=docker depName=golang
FROM --platform=$BUILDPLATFORM golang:1.26-alpine AS builder

ARG TARGETARCH
ARG TARGETOS=linux

WORKDIR /src
COPY go.mod ./
RUN go mod download
COPY cmd/ cmd/
RUN CGO_ENABLED=0 GOOS=${TARGETOS} GOARCH=${TARGETARCH} \
    go build -trimpath -ldflags="-s -w" -o /cgiserver ./cmd/cgiserver

# renovate: datasource=docker depName=docker
FROM docker:29-cli@sha256:9ba8e32bfc35a2c7ae2feb1e3241b2778ae21dee80f4dcd31d04e1cfdea86ea2

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
ENTRYPOINT ["/usr/local/bin/entrypoint"]
