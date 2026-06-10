# Contributing to db-dumper

Notes specific to this repo. For the org-wide workflow, commit
conventions, and policies, the generic
[cplieger contributing guide](https://github.com/cplieger/.github/blob/main/CONTRIBUTING.md)
still applies; this file only covers what is particular to db-dumper.

## Architecture: one Go binary, three CGI scripts, shared sh libs

db-dumper is an on-demand PostgreSQL backup sidecar. It ships two
runtimes that you need to keep straight when editing:

- **`cmd/cgiserver/main.go`** — a tiny Go HTTP server (`net/http/cgi`)
  that replaces busybox `httpd`. It serves `/cgi-bin/*` by exec'ing the
  matching script. It is the only Go in the image.
- **POSIX `sh` scripts** — the actual logic. `dump.sh` and `health.sh`
  are installed as the CGI scripts (`/srv/cgi-bin/dump`,
  `/srv/cgi-bin/health`); `entrypoint.sh` does startup cleanup then
  backgrounds the server.
- **`lib/*.sh`** — shared helpers sourced at runtime: `log.sh`
  (structured `level=... msg="..." key=value` logging), `http.sh` (CGI
  response writers), `validate.sh` (input validation).

The scripts target Alpine's busybox `ash`, not bash. Keep them
`#!/bin/sh`-clean.

### Source paths vs. image paths

`lib/*.sh` lives at the repo root under `lib/` but is copied to
`/usr/local/lib/` in the image (see the `COPY` lines in the
`Dockerfile`), which is why every script sources
`/usr/local/lib/log.sh` and friends with an absolute path. The
`# shellcheck source-path=SCRIPTDIR source=lib/log.sh` directives above
each `.` line are what let shellcheck resolve the source locally
despite the runtime path differing. If you add a new lib or a new
script, mirror both: add the `COPY --chmod=755` line in the
`Dockerfile` and the `shellcheck source=` directive at the call site.

### dump.sh request pipeline

`dump.sh` processes each `DB_SPECS` entry through three functions in
order — keep this separation when extending it:

1. `validate_dump_spec` — parse `container:dbname:user`, validate each
   identifier, reject duplicate dbnames (first one wins).
2. `execute_dump` — `mktemp` inside `DUMP_DIR` (so the final `mv` is an
   atomic same-filesystem rename), then `timeout -k ... docker exec
   <container> pg_dump --format=custom ... -- <dbname>`.
3. `classify_result` — map the exit code to a `reason`
   (`timeout`/`killed`/`pg_error`/`docker_error`/`other`), and on
   success verify the dump with `pg_restore --list` (a TOC check)
   before the atomic rename.

## Gotchas that will trip you up

- **Health endpoint always returns HTTP 200.** `health.sh` encodes the
  verdict in the response *body* (`ok` or `unhealthy: <reasons>`), not
  the status code. This is deliberate — busybox `wget` discards bodies
  on non-2xx — and there is a comment block in `health.sh` warning not
  to "fix" it back to 503. The `Dockerfile` `HEALTHCHECK` parses the
  body (`case "$body" in ok*)`).
- **New env vars must be added to the `InheritEnv` allowlist.** Go's
  `cgi.Handler` only forwards the standard CGI vars by default, so
  `main.go` lists `DB_SPECS`, `DUMP_DIR`, `DUMP_TIMEOUT`, and
  `DUMP_FREE_KB_WARN` in `InheritEnv`. A new tunable read by a script
  must be added there or the script will see it empty.
- **Verify-before-replace is load-bearing.** A dump only overwrites the
  previous `<dbname>.dump` after it passes the empty-file and
  `pg_restore --list` checks. Don't short-circuit this — a truncated
  dump silently clobbering a known-good backup is the exact failure the
  staging temp file plus atomic rename exist to prevent.
- **Orphan dumps are logged, never deleted.** A `<dbname>.dump` no
  longer in `DB_SPECS` is flagged at startup (`warn_orphan_dumps`) but
  left in place, so a misconfigured `DB_SPECS` cannot wipe real
  backups. Keep it that way.
- **`validate.sh` return contract.** Every `validate_*` returns 0 for
  valid, 1 for invalid, and prints a `level=error` line to stderr on
  failure. New validators should follow the same contract.
- **Identifier validation feeds a shell command.** `DB_SPECS` values
  reach `pg_dump`, so they are restricted to `[a-zA-Z0-9_-]`, must not
  start with `-`, and reject control chars and `..`. `--` is passed
  before the dbname as defense in depth. Don't loosen this.

## Building and validating locally

There is no Go test suite (the binary is a thin CGI shim); validation
is build + lint:

```sh
# Go: build the CGI server and run the linters (golangci-lint v2 also
# enforces gofumpt + gci formatting, so a format drift fails the run).
go build ./cmd/cgiserver
golangci-lint run
golangci-lint fmt   # apply formatting fixes

# Shell: lint every script against the busybox sh target.
shellcheck entrypoint.sh dump.sh health.sh lib/*.sh

# Image: BuildKit checks are errors (`# check=error=true` at the top of
# the Dockerfile), so a build surfaces Dockerfile lint failures too.
docker build -t db-dumper .
```

CI runs the same Go battery (vet, golangci-lint, race, govulncheck) via
the shared `cplieger/ci` reusable workflow referenced from
`.github/workflows/ci.yaml` — there is nothing repo-specific to
configure.

## Commits and PRs

Commits follow
[Conventional Commits](https://www.conventionalcommits.org/); git-cliff
parses them for the release changelog, so write the subject as the
changelog line a user pulling the image would read (`feat: ...`,
`fix: ...`, `sec: ...`). Branch from `main` and open a PR.

## Conduct & security

By participating you agree to the
[Code of Conduct](https://github.com/cplieger/.github/blob/main/CODE_OF_CONDUCT.md).
Report vulnerabilities through the
[security policy](https://github.com/cplieger/.github/blob/main/SECURITY.md),
never in a public issue.
