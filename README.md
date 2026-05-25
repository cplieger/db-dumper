# db-dumper

![License: GPL-3.0](https://img.shields.io/badge/license-GPL--3.0-blue)
[![GitHub release](https://img.shields.io/github/v/release/cplieger/db-dumper)](https://github.com/cplieger/db-dumper/releases)
[![Image Size](https://ghcr-badge.egpl.dev/cplieger/db-dumper/size)](https://github.com/cplieger/db-dumper/pkgs/container/db-dumper)
![Platforms](https://img.shields.io/badge/platforms-amd64%20%7C%20arm64-blue)
![base: docker 29-cli](https://img.shields.io/badge/base-docker_29--cli-2496ED?logo=docker)

HTTP-triggered PostgreSQL dump sidecar for sibling Postgres containers

## Overview

A small sidecar that runs `pg_dump` against one or more PostgreSQL containers
on demand, triggered by an HTTP request. Mount the Docker socket, point it at
your sibling Postgres containers via a single env var, and the sidecar produces
custom-format `.dump` files in a shared volume each time you hit its endpoint.

It's designed to slot into a backup pipeline: trigger it from a cron scheduler,
a snapshot tool's pre-script, or any orchestrator that can make an HTTP
request, and let your existing backup software (Kopia, Restic, Borg, rsync,
whatever you already use) pick up the resulting dump files afterwards.

**Example use case:** You run multiple PostgreSQL containers (Authentik,
Immich, Paperless-ngx, etc.) and want point-in-time logical dumps right before
your nightly snapshot or off-site sync. Point your scheduler at
`http://db-dumper:9847/cgi-bin/dump` once a night; the sidecar dumps every
configured database into `/dumps` as a `<dbname>.dump` file. Your snapshot
tool then captures the result in a single, consistent backup window.

**Key features:**
- HTTP-triggered: `GET /cgi-bin/dump` runs every configured dump,
  `GET /cgi-bin/health` reports liveness
- Multi-database: configure any number of `container:dbname:user` tuples in
  a single `DB_SPECS` env var; databases are dumped serially with a
  per-dump timeout
- Atomic writes with verification: a dump only replaces the previous
  `<dbname>.dump` if `pg_dump` succeeds **and** the output passes a
  `pg_restore --list` TOC check, so partial or truncated dumps never
  overwrite a good backup
- Concurrency lock: parallel dump requests are rejected with HTTP 429
  rather than hammering the source database
- Structured logs to stdout/stderr (`level=info msg="..." key=value`) for
  collection by Loki, Promtail, or any structured log scraper
- Crash-safe by design: stale temp files are cleaned at startup; orphan
  `<dbname>.dump` files no longer in `DB_SPECS` are flagged in the logs
  but never auto-deleted, so a misconfigured `DB_SPECS` cannot wipe real
  backups
- Low-disk warning when free space on the dump volume falls below
  `DUMP_FREE_KB_WARN`

This is a minimal Alpine-based container built on `docker:29-cli` — just
enough to run `pg_dump` over a Docker socket via `docker exec`. It runs as
root because Docker socket access requires it.

## Container Registries

This image is published to both GHCR and Docker Hub:

| Registry | Image |
|----------|-------|
| GHCR | `ghcr.io/cplieger/db-dumper` |
| Docker Hub | `docker.io/cplieger/db-dumper` |

```bash
# Pull from GHCR
docker pull ghcr.io/cplieger/db-dumper:latest

# Pull from Docker Hub
docker pull cplieger/db-dumper:latest
```

Both registries receive identical images and tags. Use whichever you prefer.

## Quick Start

```yaml
services:
  db-dumper:
    image: ghcr.io/cplieger/db-dumper:latest
    container_name: db-dumper
    restart: unless-stopped
    user: "0:0"  # required for docker socket access

    environment:
      TZ: "Europe/Paris"
      # Space-separated container:dbname:user tuples
      DB_SPECS: "myapp-db:myapp:postgres other-db:reports:reports"
      DUMP_TIMEOUT: "300"              # per-dump timeout in seconds (min 10)
      DUMP_FREE_KB_WARN: "1048576"     # warn when /dumps falls below 1 GiB

    ports:
      - "9847:9847"

    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - "/opt/appdata/db-dumper/dumps:/dumps"
```

Trigger a dump:

```bash
curl http://db-dumper:9847/cgi-bin/dump
# myapp: ok (4823104 bytes)
# reports: ok (892448 bytes)
```

Check health:

```bash
curl http://db-dumper:9847/cgi-bin/health
# ok
# (or, if degraded:)
# unhealthy: DB_SPECS_empty docker_unreachable
```

## Deployment

1. Set `DB_SPECS` to a space-separated list of `container:dbname:user`
   tuples — one per database you want dumped. The container name must
   resolve over the Docker socket; the database name and user are passed
   directly to `pg_dump`.
2. Mount `/var/run/docker.sock` so the sidecar can `docker exec` into
   sibling containers. This requires the container to run as root.
3. Mount a persistent directory at `/dumps` for the output files. Each
   database produces a single `<dbname>.dump` file in pg_dump's custom
   binary format (compressed, suitable for `pg_restore`).
4. Trigger dumps with an HTTP `GET` (or `POST`) to `/cgi-bin/dump` —
   typically from a cron scheduler, a snapshot tool's pre-script, or any
   orchestrator. The endpoint runs `pg_dump` for every configured database
   serially and returns a per-database status line.
5. Tune `DUMP_TIMEOUT` based on your largest database. The default
   (300s) is fine for small databases; raise it if you see `reason=timeout`
   in the logs.
6. The dump volume's free space is checked at the start of every request.
   If it falls below `DUMP_FREE_KB_WARN` (default 1 GiB), a `level=warn`
   log is emitted so you can alert on it.

When you remove a database from `DB_SPECS`, its existing `<dbname>.dump`
file is left in place — the entrypoint logs a warning at startup so you
can review and delete orphaned dumps by hand.

## API Reference

| Path | Method | Description |
|------|--------|-------------|
| `/cgi-bin/dump` | `GET`, `POST` | Run `pg_dump` for every database in `DB_SPECS`. Returns one line per database with status and size. HTTP 200 if all dumps succeed; HTTP 500 if any dump fails or the request body is invalid; HTTP 503 if the Docker daemon is unreachable from inside the container; HTTP 429 if a dump is already in progress; HTTP 405 for any method other than `GET` or `POST`. |
| `/cgi-bin/health` | `GET` | Liveness probe. Always returns HTTP 200; the body — not the status code — encodes health (`ok` or `unhealthy: <reasons>`). |

The dump endpoint emits one line per database in the response body. Successful
dumps include the file size in bytes; failures include a short reason:

```
myapp: ok (4823104 bytes)
reports: dump succeeded but file is empty
analytics: dump appears truncated (TOC unreadable)
metrics: dump failed (timeout)
billing: duplicate dbname in DB_SPECS (kept first)
bad-spec: invalid format (expected container:dbname:user)
```

Failures inside `pg_dump` itself surface as `dump failed (<reason>)` where
`<reason>` is one of `timeout`, `killed`, `pg_error`, `docker_error`, or
`other`. Each failure also produces a `level=error` structured log line
with the same `reason` field, plus the database name, the target container,
and the duration in seconds.

## Environment Variables

| Variable | Description | Default | Required |
|----------|-------------|---------|----------|
| `TZ` | Container timezone | `Europe/Paris` | No |
| `DB_SPECS` | Space-separated list of `container:dbname:user` tuples. Identifiers must contain only `[a-zA-Z0-9_-]` and must not start with `-`; specs that fail validation are reported per-database in the response and skipped. Example: `myapp-db:myapp:postgres other-db:reports:reports`. | - | Yes |
| `DUMP_DIR` | Output directory inside the container. The default lines up with the `/dumps` mount in the compose example. Values containing `..` are rejected to prevent path traversal. | `/dumps` | No |
| `DUMP_TIMEOUT` | Per-dump timeout in seconds. Minimum 10s; values below or non-numeric input fall back to the default. After the soft `SIGTERM` deadline, a `SIGKILL` follows after `DUMP_TIMEOUT / 10` seconds (clamped to 10–60s). | `300` | No |
| `DUMP_FREE_KB_WARN` | Disk-space warning threshold in KB. When free space on `/dumps` falls below this at the start of a request, a `level=warn` log is emitted. Set `0` to keep the check active but unreachable. | `1048576` (1 GiB) | No |
| `LISTEN_ADDR` | Override the HTTP listen address of the embedded Go CGI server. Advanced — the default already maps to the exposed port. | `:9847` | No |
| `CGI_DIR` | Override the directory the CGI server scans for scripts. Advanced — the default already lines up with where the entrypoint installs `dump` and `health`. | `/srv/cgi-bin` | No |

## Volumes

| Mount | Description |
|-------|-------------|
| `/var/run/docker.sock` | Docker socket. Required for `docker exec` into sibling Postgres containers. |
| `/dumps` | Output directory for `<dbname>.dump` files. Mount a persistent volume or host path so dumps survive container restarts. |

## Ports

| Port | Description |
|------|-------------|
| `9847` | HTTP CGI server. Handles `/cgi-bin/dump` and `/cgi-bin/health`. |

## Docker Healthcheck

The container ships a built-in Docker healthcheck (interval 30s, timeout 5s,
3 retries, 15s start period) that probes `/cgi-bin/health`. The endpoint
always returns HTTP 200; the body encodes whether the service is healthy
(`ok`) or degraded (`unhealthy: <reasons>`).

**When it becomes unhealthy:**
- `DB_SPECS` is empty (no databases configured)
- `/dumps` is not writable (volume missing or read-only)
- The Docker daemon is unreachable from inside the container (socket not
  mounted, daemon stopped)

**When it recovers:**
- The next health probe succeeds. No restart needed once the underlying
  problem (env var, volume mount, daemon connectivity) is resolved.

| Type | Command | Meaning |
|------|---------|---------|
| HTTP | `GET /cgi-bin/health` | Body starts with `ok` = service ready to accept dump requests |

## Security

This is a thin sidecar exposing a single HTTP endpoint over a Docker
socket — careful input handling is the main concern. The container:

- Validates `DB_SPECS` shape and each identifier against `[a-zA-Z0-9_-]`,
  rejecting empty values and identifiers that start with `-` (so they
  cannot be parsed as `pg_dump` flags)
- Rejects control characters and path-traversal sequences in env vars
- Passes `--` before the database name on the `pg_dump` command line as
  defense in depth
- Rejects any HTTP method other than `GET` and `POST`
- Holds an exclusive `flock` for the duration of every dump request, so
  parallel triggers can't double-dump or race on the temp file
- Writes `.dump` files at mode `0600` via `umask 0077`, then atomic-renames

This container runs as **root** because Docker socket access requires it.
Anyone able to reach the HTTP endpoint can trigger `pg_dump` against the
configured databases — bind it to a private network or place it behind
authentication if exposed beyond `localhost`. Mounting `docker.sock` is
equivalent to giving root on the host, so anyone who can edit `DB_SPECS`
or the compose file can escalate.

## Dependencies

All dependencies are updated automatically via [Renovate](https://github.com/renovatebot/renovate) and pinned by digest for reproducibility.

| Dependency | Version | Source |
|------------|---------|--------|
| docker | `29-cli` | [Docker Hub](https://hub.docker.com/_/docker) |
| golang (build only) | `1.26-alpine` | [Go](https://hub.docker.com/_/golang) |

## Design Principles

- **Always up to date**: Base images and libraries are updated automatically via Renovate.
- **Minimal attack surface**: A small Alpine-based image; the embedded HTTP server is a tiny Go binary that does nothing but route to the CGI scripts.
- **Digest-pinned**: Every `FROM` instruction pins a SHA256 digest. All GitHub Actions are digest-pinned.
- **Multi-platform**: Built for `linux/amd64` and `linux/arm64`.
- **Healthchecks**: The built-in `HEALTHCHECK` probes the real preconditions for a successful dump (env vars, volume, Docker socket), not just HTTP liveness.
- **Provenance**: Build provenance is attested via GitHub Actions, verifiable with `gh attestation verify`. SBOMs are generated with Syft and signed with Cosign.

## Credits

This is an original tool that builds upon
[PostgreSQL `pg_dump`](https://www.postgresql.org/docs/current/app-pgdump.html).
- [PostgreSQL](https://www.postgresql.org/) — `pg_dump` and `pg_restore`
- [Docker CLI](https://github.com/docker/cli) — Docker Engine client
  used to exec into sibling containers

## Disclaimer

These images are built with care and follow security best practices, but they are intended for **homelab use**. No guarantees of fitness for production environments. Use at your own risk.

This project was built with AI-assisted tooling using [Claude Opus](https://www.anthropic.com/claude) and [Kiro](https://kiro.dev). The human maintainer defines architecture, supervises implementation, and makes all final decisions.

## License

This project is licensed under the [GNU General Public License v3.0](LICENSE).
