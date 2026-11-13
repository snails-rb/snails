#!/bin/bash
# Dev server runner — build the app and serve it in the foreground.
#
# Core engine, run through the CLI (`snails harness dev <app_root>`) — the
# app tree carries no copy of this script (a seeded copy drifts; the
# generated bin/dev wrapper hands off here). The gate engine
# (`snails harness test`) is the throwaway counterpart: it uses the same
# build and adapter-selection steps but a one-shot database, test.env, the
# harness bundle, and teardown. This runner only serves, and its databases
# persist across boots.
#
# usage: snails harness dev <app_root> [--force] [--skip-build] [--fresh] [--verbose] [-- <binary args>]
#   <app_root>    spin root — the directory holding harness/
#   --force       serve even when snails-core/ does not match its declared
#                 source (SNALS_SOURCE), e.g. a hand-edited vendored copy
#                 or an unreachable pin; step 1 says so in one line
#   --skip-build  serve the existing build/bin/<name> (no spin build)
#   --fresh       recreate the adapter's development database first (see below)
#   --verbose     list the pending migration labels and the full repair
#                 command (default: one repair line)
#
# Environment:
#   SPINEL_SRC=<dir>       spin root (default: <app_root>)
#   PORT=<n>               listen port (default 3000 — the app's own default)
#   SNAILS_CLI=<path>      the snails CLI that invoked this engine (set by
#                          the CLI; fallback: SNAILS_DIR, then `snails`
#                          on PATH — the pin declaration gate in step 0
#                          and snails-core/ assembly in step 1 need it)
#   PG_URL=<conninfo>      pg adapter: develop against this database as-is
#                          (no container, no DDL, no loader). When unset the
#                          runner starts its own development container.
#   PG_CONTAINER_NAME      pg adapter: dev container name (default <APP_NAME>-dev-pg)
#   PG_PORT=<n>            pg adapter: dev container host port (default 5433)
#   PG_DATABASE            pg adapter: database in the dev container
#                          (default <APP_NAME>_development)
#   DATABASE_PATH=<path>   sqlite adapter: database file (default
#                          storage/development.sqlite3 under the spin root)
#
# DB adapter rules (read from the app's database configuration,
# config/database.rb — specifically the anchored require line, via
# cli/database-adapter.sh):
#   sqlite => storage/development.sqlite3 (persistent). The runner never
#     creates or loads the database — the boot check stops an uninitialized
#     target and prints the explicit `migrate load` command. An existing
#     file is left alone so development data survives.
#   pg => with PG_URL, the database belongs to the developer and is used
#     as-is: no container, no DDL, no loader (a shared or web database
#     carries extensions and data that this repo's schema dump would
#     clobber), and --fresh is refused. Without PG_URL the runner starts
#     (or reuses) a persistent development container named from APP_NAME
#     (pins.toml — the definitive app name, never the directory name), and
#     refuses to start if its port is taken. The container is infrastructure
#     only; the database inside it is initialized by the explicit
#     `migrate load`.
#
# Before the build, every target is checked (`migrate check`, read-only): an
# uninitialized database, or a schema that is behind the app's db/migrate
# files, shows up only as background-job failures, never as a failed request,
# so the server stops with the repair line instead. The runner never
# creates, loads, or applies anything: a fresh database has no ledger, and
# the check stops the boot until the developer runs the printed `migrate load`
# (or `migrate apply` for pending migrations on an initialized database).
#
# The spinel build itself is pinned by the project pins file (SPINEL_REV):
# cli/toolchain.sh (this engine's tree, versioned with the CLI) puts
# the pinned toolchain on PATH — materializing it through the snails CLI when
# the project copy under the pins file's directory is missing or stale.
#
# `harness/dev.env` (KEY=val), when present, is exported into the server
# environment as the app's development settings. Its test counterpart is
# test.env, which is server-only and test-only; this engine never sources it.
# The server runs in the foreground: its output goes to the terminal and
# is appended to the app tree's tmp/development.log (the tmp/ is
# gitignored, so the log is local state, never source). Ctrl-C stops the
# server; the log and the adapter's database (the sqlite file or the dev
# container) are untouched.
set -euo pipefail

ENGINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=app-root.sh
source "$ENGINE_DIR/app-root.sh"
# shellcheck source=vendor-dir.sh
source "$ENGINE_DIR/vendor-dir.sh"
# shellcheck source=generators.sh
source "$ENGINE_DIR/generators.sh"
# The pins file (location + format) is the shared resolution, not a copy.
# shellcheck source=pins.sh
source "$ENGINE_DIR/pins.sh"
[[ -n ${1:-} && -d ${1:-} ]] || {
  echo "[snails] usage: snails harness dev <app_root> [--force] [--skip-build] [--fresh] [--verbose] [-- <binary args>] (app_root must be a directory)" >&2
  exit 2
}
APP_ROOT="$(cd "$1" && pwd)"
shift
[[ -d "$APP_ROOT/harness" ]] || {
  echo "[snails] no harness/ under $APP_ROOT — the app target is seeded by 'snails sync' on scaffold trees" >&2
  exit 1
}
HARNESS_DIR="$APP_ROOT/harness"
SPIN_ROOT="${SPINEL_SRC:-$APP_ROOT}"
PORT="${PORT:-3000}"


SKIP_BUILD=0
FRESH=0
VERBOSE=0
BIN_ARGS=()
FORCE=0
while (($#)); do
  case "$1" in
    --force)      FORCE=1; shift ;;
    --skip-build) SKIP_BUILD=1; shift ;;
    --fresh)      FRESH=1; shift ;;
    --verbose)    VERBOSE=1; shift ;;
    --)           shift; BIN_ARGS=("$@"); break ;;
    -h|--help)
      sed -n '2,76p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "[snails] unknown argument: $1 (usage: snails harness dev <app_root> [--force] [--skip-build] [--fresh] [--verbose] [-- <binary args>])" >&2; exit 2 ;;
  esac
done

# The CLI that invoked this engine is authoritative (SNAILS_CLI, set by
# `snails harness ...`); the fallback locates one without hardcoding a local
# path: SNAILS_DIR (the checkout) wins, else `snails` on PATH.
# The pin declaration gate in step 0 and snails-core/ assembly in step 1
# need it.
snails_cli() {
  if [[ -n ${SNAILS_CLI:-} ]]; then
    printf '%s\n' "$SNAILS_CLI"
  elif [[ -n ${SNAILS_DIR:-} ]]; then
    printf '%s\n' "$SNAILS_DIR/bin/snails"
  else
    command -v snails 2>/dev/null || true
  fi
}

# The boot check: an uninitialized database, or an existing schema that is
# behind the app's db/migrate files, appears only as background-job failures,
# so stop here instead. Read-only: the repair is the explicit `migrate load`
# or `migrate apply` step, never this check. A database the runner started
# itself (the pg dev container) is named in the repair line because the
# developer's shell does not carry the runner's exported PG_URL.
# (The gate engine owns its own schema dump loader; the dev runner never loads
# or applies anything.)
check_pending_migrations() {
  local args=(--app "$SPIN_ROOT")
  if [[ ${PG_URL_FROM_RUNNER:-0} -eq 1 ]]; then
    args+=(--database "$PG_URL")
  fi
  ((VERBOSE)) && args+=(--verbose)
  "$CLI" migrate check "${args[@]}"
}

# Pin the spinel build to the project's SPINEL_REV before anything compiles.
# The resolver lives in this engine's tree (core-owned, versioned with the
# CLI) — the app tree carries no copy of it.
# shellcheck source=toolchain.sh
source "$ENGINE_DIR/toolchain.sh"
# shellcheck source=database-adapter.sh
source "$ENGINE_DIR/database-adapter.sh"
# shellcheck source=core-check.sh
source "$ENGINE_DIR/core-check.sh"

# 0. Pin declaration gate — the CLI owns the check (`verify-pins`): a
#    restorable SNALS_REV, plus a SPINEL_REV that matches the pin record at
#    that revision. It runs before anything is materialized from the pins. A
#    tree without a pins file has no declaration to check: it keeps the
#    pre-declaration behavior, and says so. The runner probes no app script;
#    app-specific checks live in the app-owned bin/test and bin/dev wrappers
#    (the check-pins hook is retired).
CLI="$(snails_cli)"
[[ -n $CLI && -x $CLI ]] || {
  echo "[snails] snails CLI not found; set SNAILS_DIR to the snails checkout (or put snails on PATH)" >&2
  exit 1
}
if [[ -z "$(pins_discover "$SPIN_ROOT")" ]]; then
  echo "[snails] no pins file above $SPIN_ROOT — pin declaration check skipped" >&2
elif "$CLI" verify-pins -h >/dev/null 2>&1; then
  "$CLI" verify-pins "$SPIN_ROOT" >&2
else
  echo "[snails] the resolved CLI predates verify-pins — pin declaration check skipped" >&2
fi

# The pinned toolchain goes on PATH before anything compiles (materialized
# through the CLI when the project copy is missing or stale — toolchain.sh).
spinel_toolchain_env "$SPIN_ROOT"

command -v spin >/dev/null || { echo "[snails] spin not found" >&2; exit 1; }

# 1. snails-core/ — the pins file declares the build source: "pin"
#    restores SNALS_REV, "checkout" takes the core checkout's working tree.
#    `snails new` writes the source it vendored from, so a core developer's
#    app (checkout) and a consumer's pinned app (pin) each verify exactly
#    one source — no guessing or fallback. Assemble the core when it is missing
#    (it is not committed; `snails sync` vendors it).
if [[ ! -d "$SPIN_ROOT/$SNAILS_VENDOR_DIR" ]]; then
  "$CLI" sync "$SPIN_ROOT" >&2
elif ((FORCE)); then
  # Same rule as the gate: --force is the developer's own call, per
  # invocation. The check still runs so the drift is visible.
  if ! core_check "$CLI" "$SPIN_ROOT"; then
    echo "[snails] serving $SNAILS_VENDOR_DIR/ as-is, not checked against its declared source (--force)" >&2
  fi
elif core_check "$CLI" "$SPIN_ROOT"; then
  if [[ $CORE_SOURCE == "checkout" ]]; then
    echo "[snails] serving $SNAILS_VENDOR_DIR/ from the checkout working tree, not the pin (SNALS_SOURCE=checkout)" >&2
  fi
else
  # Never re-sync without the developer's knowledge: a dev server is exactly
  # where local core edits live, and a rewrite could race a parallel server
  # and hide the drift (including deliberate edits to the vendored copy and
  # partial corruption) that the check exists to surface.
  repair_arg="$(app_root_argument "$SPIN_ROOT")"
  sync_command="snails sync"
  [[ -n $repair_arg ]] && sync_command+=" $(shell_quote "$repair_arg")"
  force_command="snails harness dev"
  [[ -n $repair_arg ]] && force_command+=" $(shell_quote "$repair_arg")"
  force_command+=" --force"
  echo "[snails] stopped before the build — run: $sync_command (the check above says why)" >&2
  echo "[snails] to serve the tree as it stands instead: $force_command" >&2
  exit 1
fi

# 2. Resolve the DB adapter before building: a missing database must stop in
#    seconds, not after a full compile. sqlite owns a persistent file; the
#    pg adapter uses PG_URL as-is, or starts its own development container.
DB_ADAPTER="$(database_adapter_for "$SPIN_ROOT")" || exit 1
PG_URL_FROM_RUNNER=0
if [[ $DB_ADAPTER == pg ]]; then
  if [[ -n ${PG_URL:-} ]]; then
    # Developer-provided database — used as-is: no container, no DDL, no
    # loader (a shared or web database carries extensions and data that this
    # repo's schema dump would clobber), and --fresh is refused.
    if ((FRESH)); then
      echo "[snails] --fresh applies to the dev container only — a provided PG_URL belongs to its owner" >&2
      exit 1
    fi
  else
    # No PG_URL: bring up this app's persistent development database
    # container. APP_NAME (pins.toml) is the definitive app name, never the
    # directory name (a rename, worktree, or clone would let it drift).
    PG_URL_FROM_RUNNER=1
    pins="$(pins_discover "$SPIN_ROOT")"
    APP_NAME=""
    [[ -z $pins ]] || APP_NAME="$(pins_get "$pins" APP_NAME)"
    [[ -n $APP_NAME ]] || {
      echo "[snails] pins.toml has no APP_NAME=\"<app>\" — the app name is required for the dev database and container name" >&2
      exit 1
    }
    DEV_CONTAINER="${PG_CONTAINER_NAME:-$APP_NAME-dev-pg}"
    DEV_PORT="${PG_PORT:-5433}"
    DEV_DB="${PG_DATABASE:-${APP_NAME//[^a-zA-Z0-9]/_}_development}"
    command -v docker >/dev/null || {
      echo "[snails] docker not found — the pg adapter needs a database: pass PG_URL, or install docker for the dev container" >&2
      exit 1
    }
    NEW_CONTAINER=0
    if docker inspect "$DEV_CONTAINER" >/dev/null 2>&1; then
      if ((FRESH)); then
        docker rm -fv "$DEV_CONTAINER" >/dev/null
        NEW_CONTAINER=1
      else
        docker start "$DEV_CONTAINER" >/dev/null
      fi
    else
      NEW_CONTAINER=1
    fi
    if ((NEW_CONTAINER)); then
      # Running two apps at once is the developer's call. Use the fixed
      # default port, but never take a busy port silently: report it and let
      # the developer move this app with PG_PORT.
      if (echo >"/dev/tcp/127.0.0.1/$DEV_PORT") 2>/dev/null; then
        echo "[snails] port $DEV_PORT is already in use (another app's dev database?)" >&2
        echo "[snails] to run this app alongside it, set PG_PORT to a free port" >&2
        exit 1
      fi
      if ! docker run -d --name "$DEV_CONTAINER" \
        -e POSTGRES_PASSWORD=postgres -e POSTGRES_DB="$DEV_DB" \
        -p "$DEV_PORT:5432" postgres:18-alpine >/dev/null; then
        echo "[snails] could not start the dev database container (docker error above). If port $DEV_PORT is taken, set PG_PORT=<free port>." >&2
        exit 1
      fi
    fi
    export PG_URL="postgres://postgres:postgres@127.0.0.1:$DEV_PORT/$DEV_DB"
    pg_ready=""
    for _ in $(seq 1 30); do
      if psql "$PG_URL" -tAc "SELECT 1" >/dev/null 2>&1; then
        pg_ready=1
        break
      fi
      sleep 1
    done
    if [[ -z $pg_ready ]]; then
      echo "[snails] dev database container did not start. docker logs:" >&2
      docker logs "$DEV_CONTAINER" >&2
      exit 1
    fi
    # The container is infrastructure only; the database inside it is
    # initialized by the explicit `migrate load` the boot check prints.
    echo "[snails] dev database: $DEV_CONTAINER @ 127.0.0.1:$DEV_PORT/$DEV_DB" >&2
  fi
else
  mkdir -p "$SPIN_ROOT/storage"
  export DATABASE_PATH="${DATABASE_PATH:-$SPIN_ROOT/storage/development.sqlite3}"
  if ((FRESH)); then
    rm -f "$DATABASE_PATH" "$DATABASE_PATH-wal" "$DATABASE_PATH-shm"
  fi
  # The runner never creates or loads the database; the boot check prints
  # the explicit `migrate load` command for an uninitialized target.
fi

# 3. Database readiness check — read-only, and before the build, so an
#    uninitialized or stale schema costs seconds rather than a background-job
#    failure while the server is running. The runner never writes the database:
#    the repair line is the developer's explicit `snails migrate load`
#    (uninitialized) or `snails migrate apply` (pending).
check_pending_migrations

# 4. Build the server (incremental). gen/* is refreshed first
#    (cli/generators.sh), so the compile sees the tree as it stands — and
#    only when building: --skip-build serves the existing artifact and
#    regenerates nothing.
if ((SKIP_BUILD == 0)); then
  run_generators "$CLI" "$SPIN_ROOT" >&2
  ( cd "$SPIN_ROOT" && spin build ) >&2
fi

BINS=("$SPIN_ROOT"/bin/*.rb)
[[ ${#BINS[@]} -eq 1 ]] || { echo "[snails] expected exactly one bin/*.rb target: ${BINS[*]:-none}" >&2; exit 1; }
NAME="$(basename "${BINS[0]}" .rb)"
BIN="$SPIN_ROOT/build/bin/$NAME"
[[ -x $BIN ]] || { echo "[snails] binary not found: $BIN (drop --skip-build or run spin build)" >&2; exit 1; }

# 5. Serve in the foreground. The port must be free first: a foreign
#    listener would take the client's requests. dev.env, when present,
#    holds the app's development settings, exported into this server
#    environment (test.env belongs to the gate and is never sourced here).
if (echo > /dev/tcp/127.0.0.1/"$PORT") 2>/dev/null; then
  echo "[snails] port $PORT is already in use" >&2
  exit 1
fi
if [[ -f "$HARNESS_DIR/dev.env" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "$HARNESS_DIR/dev.env"
  set +a
fi
echo "[snails] serving $NAME on http://127.0.0.1:$PORT"
# Hand the terminal to the binary: exec so Ctrl-C (and a caller's kill)
# hit the server itself. Output is mirrored to the app tree's
# tmp/development.log (append): the tmp/ is gitignored, so the log is local
# state, never source.
LOG="$SPIN_ROOT/tmp/development.log"
mkdir -p "$SPIN_ROOT/tmp"
echo "[snails] log: tmp/development.log (append)"
PORT="$PORT" exec "$BIN" "${BIN_ARGS[@]+"${BIN_ARGS[@]}"}" > >(tee -a "$LOG") 2>&1
