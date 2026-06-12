# db-dumper

[![CI](https://github.com/cplieger/db-dumper/actions/workflows/ci.yaml/badge.svg)](https://github.com/cplieger/db-dumper/actions/workflows/ci.yaml)
[![GitHub release](https://img.shields.io/github/v/release/cplieger/db-dumper)](https://github.com/cplieger/db-dumper/releases)
[![Image Size](https://ghcr-badge.egpl.dev/cplieger/db-dumper/size)](https://github.com/cplieger/db-dumper/pkgs/container/db-dumper)
![Platforms](https://img.shields.io/badge/platforms-amd64%20%7C%20arm64-blue)
![base: Alpine](https://img.shields.io/badge/base-Alpine-0D597F?logo=alpinelinux)
[![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/cplieger/db-dumper/badge)](https://scorecard.dev/viewer/?uri=github.com/cplieger/db-dumper)
[![License: GPL-3.0](https://img.shields.io/badge/License-GPL--3.0-blue.svg)](LICENSE)

On-demand PostgreSQL backup sidecar — hit an HTTP endpoint, get a
`.dump` file ready for your existing backup tool to pick up.

## What it does

Run this container alongside your PostgreSQL database containers. When
you make an HTTP request to its endpoint, it runs `pg_dump` against
every database you've configured and writes one `.dump` file per
database into a shared volume. Your existing backup tool (Kopia,
Restic, Borg, rsync, anything) then picks up those files on its next
pass.

A typical setup: you run several Postgres containers (Authentik,
Immich, Paperless, etc.), trigger this sidecar from cron right before
your nightly off-site sync, and your snapshot tool captures consistent
logical dumps of every database in one window.

What this image adds on top of plain `pg_dump`:

- **HTTP-triggered** — `GET /cgi-bin/dump` runs every configured dump,
  `GET /cgi-bin/health` reports liveness. No internal scheduler — your
  existing one stays in charge.
- **Multi-database** — configure any number of `container:dbname:user`
  tuples in a single `DB_SPECS` env var; databases are dumped serially
  with a per-dump timeout.
- **Atomic writes with verification** — every dump is staged to a temp
  file, validated with `pg_restore --list` (TOC check), then
  atomic-renamed over the previous `<dbname>.dump`. A partial or
  truncated dump can never overwrite a known-good backup.
- **Concurrency lock** — parallel triggers get HTTP 429 rather than
  hammering the source database.
- **Crash-safe by design** — stale temp files are cleaned at startup;
  `<dbname>.dump` files no longer in `DB_SPECS` are flagged in the logs
  but never auto-deleted, so a misconfigured `DB_SPECS` cannot wipe
  real backups.
- **Structured logs** to stdout/stderr (`level=info msg="..." key=value`)
  for collection by Loki, Grafana Agent, etc.
- **Low-disk warning** when free space on the dump volume falls below
  `DUMP_FREE_KB_WARN`.

### Why this design

Other Postgres backup tools either bundle the whole pipeline
(compression, encryption, retention, off-site sync) or schedule
themselves with built-in cron. This image takes the opposite tack:

- **HTTP-triggered, not internally scheduled.** You invoke it from
  your existing scheduler, snapshot tool, or orchestrator, so the dump
  runs in the same window as the rest of your backup pipeline.
- **Logical dumps only, not the entire pipeline.** The result is plain
  `pg_dump` custom-format files in a volume — pair it with whatever
  backup tool you already use.
- **Verification before replace.** Every dump is staged + TOC-validated
  before atomically replacing the previous copy, so corrupt output
  never overwrites a known-good backup.
- **Single env var for multiple databases.** Add a database to your
  pipeline by appending to `DB_SPECS`, no per-DB config files.

This is a minimal Alpine image (`alpine:3.23` with the `docker-cli`
package added) — just enough to run `pg_dump` over a Docker socket via
`docker exec`. It runs as root because mounting the Docker socket
requires it.

## Quick start

The image is published to both GHCR (`ghcr.io/cplieger/db-dumper`) and
Docker Hub (`cplieger/db-dumper`) — identical contents, use whichever
you prefer.

```yaml
services:
  db-dumper:
    image: ghcr.io/cplieger/db-dumper:latest
    container_name: db-dumper
    restart: unless-stopped
    user: "0:0"  # required for Docker socket access

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

## API reference

| Path | Method | Description |
|------|--------|-------------|
| `/cgi-bin/dump` | `GET`, `POST` | Run `pg_dump` for every database in `DB_SPECS`. Returns one line per database with status and size. HTTP 200 on full success; 429 if a dump is already in progress; 500 on dump failure or invalid request body; 503 if the Docker daemon is unreachable; 405 for any other method. |
| `/cgi-bin/health` | `GET` | Liveness probe. Always returns HTTP 200; the **body** encodes health (`ok` or `unhealthy: <reasons>`). |

The dump endpoint emits one line per database in the response body.
Successes include the file size in bytes; failures include a short
reason:

```
myapp: ok (4823104 bytes)
reports: dump succeeded but file is empty
analytics: dump appears truncated (TOC unreadable)
metrics: dump failed (timeout)
billing: duplicate dbname in DB_SPECS (kept first)
bad-spec: invalid format (expected container:dbname:user)
```

`pg_dump` failures surface as `dump failed (<reason>)` where `<reason>`
is one of `timeout`, `killed`, `pg_error`, `docker_error`, or `other`.
Each failure also produces a `level=error` structured log line with
the same `reason` field, the database name, the target container, and
the duration in seconds.

## Configuration reference

### Environment variables

| Variable | Description | Default | Required |
|----------|-------------|---------|----------|
| `TZ` | Container timezone | `Europe/Paris` | No |
| `DB_SPECS` | Space-separated `container:dbname:user` tuples. Identifiers must contain only `[a-zA-Z0-9_-]` and must not start with `-`; specs that fail validation are reported per-database in the response and skipped. | — | Yes |
| `DUMP_DIR` | Output directory inside the container. Lines up with the `/dumps` mount in the example. Values containing `..` are rejected. | `/dumps` | No |
| `DUMP_TIMEOUT` | Per-dump timeout in seconds (minimum 10s). After the soft `SIGTERM` deadline, a `SIGKILL` follows after `DUMP_TIMEOUT / 10` seconds (clamped to 10–60s). | `300` | No |
| `DUMP_FREE_KB_WARN` | Disk-space warning threshold in KB. When free space on `/dumps` falls below this at the start of a request, a `level=warn` log is emitted. | `1048576` (1 GiB) | No |
| `LISTEN_ADDR` | HTTP listen address of the embedded Go CGI server. Advanced — the default already maps to the exposed port. | `:9847` | No |
| `CGI_DIR` | Directory the CGI server scans for scripts. Advanced — the default already lines up with where the entrypoint installs `dump` and `health`. | `/srv/cgi-bin` | No |

### Volumes

| Mount | Description |
|-------|-------------|
| `/var/run/docker.sock` | Docker socket. Required for `docker exec` into sibling Postgres containers. |
| `/dumps` | Output directory for `<dbname>.dump` files. Mount a persistent host path or named volume so dumps survive container restarts. |

### Ports

| Port | Description |
|------|-------------|
| `9847` | HTTP CGI server. Handles `/cgi-bin/dump` and `/cgi-bin/health`. |

When you remove a database from `DB_SPECS`, the existing
`<dbname>.dump` file is left in place — the entrypoint logs a warning
at startup so you can review and delete orphaned dumps by hand.

## Healthcheck

The container's built-in healthcheck probes `/cgi-bin/health` every
30s. It reports unhealthy if any of these are true:

- `DB_SPECS` is empty (no databases configured)
- `/dumps` is not writable (volume missing or read-only)
- The Docker daemon is unreachable (socket not mounted, daemon stopped)

The endpoint returns HTTP 200 either way; the **body** is what carries
the health verdict (`ok` or `unhealthy: <reasons>`). Once the
underlying issue is fixed the next probe recovers without a restart.

## Security

- All `DB_SPECS` values are validated against `[a-zA-Z0-9_-]` before
  reaching `pg_dump`. Empty values, identifiers starting with `-`
  (which could be parsed as `pg_dump` flags), control characters, and
  `..` path-traversal sequences are all rejected.
- `--` is passed before the database name on the `pg_dump` command
  line as defense in depth.
- Only `GET` and `POST` are accepted; everything else returns 405.
- Every dump request holds an exclusive `flock`, so parallel triggers
  can't race on temp files or double-dump.
- `.dump` files are written at mode `0600` via `umask 0077`, then
  atomic-renamed over the target.
- The container runs as **root** because Docker socket access requires
  it. Anyone able to reach the HTTP endpoint can trigger `pg_dump`
  against your databases — bind it to a private network or place it
  behind authentication if exposed beyond `localhost`. Mounting
  `docker.sock` is equivalent to giving root on the host, so anyone
  who can edit `DB_SPECS` or your compose file can escalate.

## Dependencies

| Dependency | Version | Source |
|------------|---------|--------|
| alpine | `3.23` | [Docker Hub](https://hub.docker.com/_/alpine) |
| docker-cli | Alpine apk package | [Alpine packages](https://pkgs.alpinelinux.org/packages?name=docker-cli) |
| tini | Alpine apk package | [Alpine packages](https://pkgs.alpinelinux.org/packages?name=tini) |
| golang (build only) | `1.26-alpine` | [Go](https://hub.docker.com/_/golang) |

Base images are updated automatically via [Renovate](https://github.com/renovatebot/renovate)
and pinned by digest; `docker-cli` and `tini` track the Alpine package
repository. Builds carry signed SBOMs and provenance attestations
verifiable with `gh attestation verify`.

## Credits

- [PostgreSQL](https://www.postgresql.org/) — `pg_dump` and `pg_restore`
- [Docker CLI](https://github.com/docker/cli) — used to exec into
  sibling containers

## Disclaimer

These images are built with care and follow security best practices,
but they are intended for **homelab use**. No guarantees of fitness
for production environments. Use at your own risk.

This project was built with AI-assisted tooling using
[Claude Opus](https://www.anthropic.com/claude) and [Kiro](https://kiro.dev).
The human maintainer defines architecture, supervises implementation,
and makes all final decisions.

## License

This project is licensed under the [GNU General Public License v3.0](LICENSE).
