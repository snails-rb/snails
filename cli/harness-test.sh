#!/bin/bash
# Harness gate — build the app's server, boot it, run the harness bundle
# against it over real HTTP, then tear down.
#
# Core engine, run through the CLI (`snails harness test <app_root>`) — the
# app tree carries no copy of this script (a seeded copy drifts; the
# generated bin/test wrapper hands off here). A consumer with a richer gate
# composes its own app-owned steps around the CLI call.
#
# usage: snails harness test <app_root> [--force] [--verbose] [-- <case file>...]
#   <app_root>  spin root — the directory holding harness/
#   --force     run even when snails-core/ does not match its declared
#               source (SNALS_SOURCE), e.g. a hand-edited vendored copy or
#               an unreachable pin; step 1 says so in one line
#   --verbose   print a failed load's full log (default: the failure line
#               names the kept log path)
#   <case file> run only these harness case files (a path under the harness
#               dir or the spin root); an unknown name fails — it never
#               widens to the whole suite
#
# Environment:
#   SPINEL_SRC=<dir>       spin root (default: <app_root>)
#   PORT=<n>               server port (default: a free port picked per
#                          run — the gate needs no known address)
#   SNAILS_CLI=<path>      the snails CLI that invoked this engine (set by
#                          the CLI; fallback: SNAILS_DIR, then `snails`
#                          on PATH — the pin declaration gate in step 0
#                          and snails-core/ assembly in step 1 need it)
#   PG_URL=<conninfo>      pg adapter: use this database as the test target
#                          instead of starting a docker container. Use a
#                          disposable database — the app schema is loaded
#                          into it. PG_CONTAINER_NAME/PG_PORT are ignored.
#   PG_CONTAINER_NAME      pg adapter: docker container (default: a per-run
#                          name — parallel suites never share one)
#   PG_PORT                pg adapter: host port (default: docker-assigned)
#   KEEP_LOG=1             keep the server log
#
# The spinel build itself is pinned by the project pins file (SPINEL_REV):
# cli/toolchain.sh (this engine's tree, versioned with the CLI) puts
# the pinned toolchain on PATH — materializing it through the snails CLI when
# the project copy under the pins file's directory is missing or stale.
#
# The DB adapter is read from the app's config/database.rb (the anchored
# require line, via cli/database-adapter.sh): pg => a one-shot postgres
# container, or PG_URL when the caller provides a disposable database;
# sqlite => a fresh sqlite file per suite via DATABASE_PATH. Both adapters
# apply the app's schema through the core loader (db/schema.sql) before the
# server boots.
# `harness/test.env` (KEY=val) is SERVER-ONLY environment, sourced inside
# the server subshell in step 4 — the test process keeps a clean ENV.
# The engine empties the app's mail capture log (`tmp/mail-capture.jsonl`
# under the spin root) before boot: the server appends to it in test mode
# (snails-core/action_mailer/base.rb DeliveryLog), and the harness library
# reads it (assert_emails/emails). Stale lines would leak into the run's log,
# as with the sqlite suite file below.
set -euo pipefail

ENGINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=app-root.sh
source "$ENGINE_DIR/app-root.sh"
# shellcheck source=vendor-dir.sh
source "$ENGINE_DIR/vendor-dir.sh"
# shellcheck source=generators.sh
source "$ENGINE_DIR/generators.sh"
[[ -n ${1:-} && -d ${1:-} ]] || {
  echo "[snails] usage: snails harness test <app_root> [--force] [--verbose] [-- <case file>...] (app_root must be a directory)" >&2
  exit 2
}
APP_ROOT="$(cd "$1" && pwd)"
shift
# --force is this engine's option, so it is consumed before the runner args;
# everything after `--` (and, for compatibility, any other argument) reaches
# the bundle runner unchanged — there, a name is a case file, and an unknown
# one fails with an error instead of running the whole suite.
FORCE=0
VERBOSE=0
RUNNER_ARGS=()
while (($#)); do
  case "$1" in
    --force)   FORCE=1; shift ;;
    --verbose) VERBOSE=1; shift ;;
    --)        shift; RUNNER_ARGS=("$@"); break ;;
    *)         RUNNER_ARGS+=("$1"); shift ;;
  esac
done
[[ -d "$APP_ROOT/harness" ]] || {
  echo "[snails] no harness/ under $APP_ROOT — the app target is seeded by 'snails sync' on scaffold trees" >&2
  exit 1
}
HARNESS_DIR="$APP_ROOT/harness"
SPIN_ROOT="${SPINEL_SRC:-$APP_ROOT}"
# PORT pins the exact gate port (a collision fails with an error; a
# developer may want a known port for debugging). Default: a free port picked
# per run.
# gate is a throwaway client target: nothing needs it at a known
# address, and a fixed default collides with every other app and suite
# on the machine. test.env is server-only and must not steer the port
# either way (an app PORT= line there is ignored).
PORT="${PORT:-}"
RUNNER_PORT=""
TMP="$(mktemp -d)"
LOG="$TMP/server.log"
PID=""
PG_CONTAINER=""

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

# Print a free high port. The probe is not atomic with the server's bind
# — another process can take the port in between — so the boot step
# retries with a fresh pick when a picked port does not survive boot.
pick_port() {
  local tries=0 port
  while (( tries < 20 )); do
    port=$(( 49152 + RANDOM % 16384 ))
    if ! (echo > /dev/tcp/127.0.0.1/"$port") 2>/dev/null; then
      printf '%s\n' "$port"
      return 0
    fi
    tries=$(( tries + 1 ))
  done
  return 1
}

# Apply the app's schema before boot. The convention is core-owned: the
# vendored loader (snails-core/snails/schema_loader.rb) is compiled from the
# spin root so it shares the app manifest, and it applies db/schema.sql
# relative to the spin root. With no schema file, nothing is loaded. The
# retired config/ layout counts as "files present" too, so the loader's
# stale-layout raise reaches the console instead of being skipped. Any loader
# failure keeps its log and names the path; swallowing it here would turn a
# clear contract failure into a bare non-zero exit.
#
# The compiled loader is cached under harness/build/ (gitignored state,
# next to the bundle runner's output): it is infrastructure, not app
# code, so recompiling it on every run was ~9s of pure overhead. The
# cache is rejected when any compile input is newer — the sources of the
# loader's boot chain (snails-core/·config/·app/·gen/), spin.toml, the
# compiler, or this engine file itself. harness/·tmp/·storage/ are not
# compile inputs and stay out of the scan.
load_schema() {
  [[ -f "$SPIN_ROOT/db/schema.sql" ||
     -f "$SPIN_ROOT/config/schema.sql" || -d "$SPIN_ROOT/config/views" ]] || return 0
  local loader="$SPIN_ROOT/$SNAILS_VENDOR_DIR/snails/schema_loader.rb"
  [[ -f $loader ]] || {
    echo "[snails] schema files present but $loader is missing — bump SNALS_REV to a core with the schema loader" >&2
    exit 1
  }
  local cached="$HARNESS_DIR/build/schema_loader"
  if [[ ! -x $cached ]] ||
    [[ -n "$(find "$SPIN_ROOT" -mindepth 1 \
      \( -name build -o -name vendor -o -name harness -o -name tmp -o -name storage -o -name '.*' \) \
      -prune -o -type f \
      \( -name '*.rb' -o -name '*.rbs' -o -name '*.c' -o -name '*.h' -o -name spin.toml \) \
      -newer "$cached" -print -quit)" ]] ||
    [[ "$(command -v spinel)" -nt "$cached" ]] ||
    [[ "${BASH_SOURCE[0]}" -nt "$cached" ]]; then
    read -r -a flags <<<"$(cd "$SPIN_ROOT" && spin flags | head -1)"
    mkdir -p "$HARNESS_DIR/build"
    local built="$cached.tmp.$$"
    rm -f "$built"
    if ! ( cd "$SPIN_ROOT" && spinel "$loader" "${flags[@]}" -O 1 -o "$built" ) >>"$LOG" 2>&1; then
      rm -f "$built"
      fail_with_log "[snails] schema loader failed to compile" "$LOG"
    fi
    mv "$built" "$cached"
  fi
  if ! ( cd "$SPIN_ROOT" && "$cached" ) >>"$LOG" 2>&1; then
    fail_with_log "[snails] schema loader failed" "$LOG"
  fi
}

# A failure keeps its log file and names the path on the failure line —
# the full log is the --verbose detail. cleanup() must not delete it.
fail_with_log() {
  local message="$1" log="$2"
  echo "$message — log kept: $log" >&2
  FAIL_KEEP_LOG=1
  if ((VERBOSE)); then
    cat "$log" >&2
  fi
  exit 1
}

cleanup() {
  if [[ -n $PID ]]; then
    kill "$PID" 2>/dev/null || true
    wait "$PID" 2>/dev/null || true
  fi
  if [[ -n $PG_CONTAINER ]]; then
    docker rm -fv "$PG_CONTAINER" >/dev/null 2>&1 || true
  fi
  if [[ -n ${FAIL_KEEP_LOG:-} ]]; then
    : # the failure line already named the kept log
  elif [[ -n ${KEEP_LOG:-} ]]; then
    echo "[snails] server log kept: $LOG" >&2
  else
    rm -rf "$TMP"
  fi
}
trap cleanup EXIT

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
#    app (checkout) and a consumer's pinned app (pin) each verify exactly one
#    source, with no guessing or fallback. Assemble the core when it is
#    missing (it is not committed; `snails sync` vendors it).
if [[ ! -d "$SPIN_ROOT/$SNAILS_VENDOR_DIR" ]]; then
  "$CLI" sync "$SPIN_ROOT" >&2
elif ((FORCE)); then
  # --force is the developer's own call, per invocation: it compiles the
  # tree as it stands and says so. The check still runs so the drift is
  # visible.
  if ! core_check "$CLI" "$SPIN_ROOT"; then
    echo "[snails] building $SNAILS_VENDOR_DIR/ as-is, not checked against its declared source (--force)" >&2
  fi
elif core_check "$CLI" "$SPIN_ROOT"; then
  if [[ $CORE_SOURCE == "checkout" ]]; then
    echo "[snails] building $SNAILS_VENDOR_DIR/ from the checkout working tree, not the pin (SNALS_SOURCE=checkout)" >&2
  fi
else
  # The gate never re-syncs without the developer's knowledge: that would
  # rewrite the tree mid-run, race a parallel dev server, and hide the drift
  # (including deliberate edits to the vendored copy and partial corruption)
  # that the check exists to surface. --force is the developer's own call, per
  # invocation, and it says so.
  repair_arg="$(app_root_argument "$SPIN_ROOT")"
  sync_command="snails sync"
  [[ -n $repair_arg ]] && sync_command+=" $(shell_quote "$repair_arg")"
  force_command="snails harness test"
  [[ -n $repair_arg ]] && force_command+=" $(shell_quote "$repair_arg")"
  force_command+=" --force"
  echo "[snails] stopped before the build — run: $sync_command (the check above says why)" >&2
  echo "[snails] to compile the tree as it stands instead: $force_command" >&2
  exit 1
fi

# 2. Build the server. gen/* is refreshed first (cli/generators.sh), so the
#    build compiles the tree as it stands and picks up any controller or
#    migration added since the last run. `spin build` writes build/bin/<name>
#    (the single bin/*.rb target names the binary).
run_generators "$CLI" "$SPIN_ROOT" >&2
( cd "$SPIN_ROOT" && spin build ) >&2

BINS=("$SPIN_ROOT"/bin/*.rb)
[[ ${#BINS[@]} -eq 1 ]] || { echo "[snails] expected exactly one bin/*.rb target: ${BINS[*]:-none}" >&2; exit 1; }
NAME="$(basename "${BINS[0]}" .rb)"
BIN="$SPIN_ROOT/build/bin/$NAME"
[[ -x $BIN ]] || { echo "[snails] binary not found: $BIN" >&2; exit 1; }

# 3. Bring up the DB adapter.
DB_ADAPTER="$(database_adapter_for "$SPIN_ROOT")" || exit 1
if [[ $DB_ADAPTER == pg ]]; then
  command -v psql >/dev/null || { echo "[snails] psql not found (pg adapter)" >&2; exit 1; }
  if [[ -n ${PG_URL:-} ]]; then
    # The caller owns this database. The schema load below is deliberate:
    # a harness suite needs the app tables, and the sqlite path gets the
    # same fresh-schema treatment. Reusing a populated database is the
    # caller's choice; the contract is "disposable test database".
    psql "$PG_URL" -tAc "SELECT 1" >/dev/null 2>&1 || {
      echo "[snails] cannot reach PG_URL — pass a disposable database for the pg adapter" >&2
      exit 1
    }
    export PG_URL
    echo "[snails] using PG_URL as the pg test database (no docker; schema loaded)" >&2
  else
    command -v docker >/dev/null || { echo "[snails] docker not found (pg adapter; pass PG_URL to use an existing database)" >&2; exit 1; }
    # Throwaway database, same rule as the server port: no shared fixed
    # defaults. The default container is named per run and its host port
    # is docker-assigned, so parallel suites never touch each other's
    # database. Explicit PG_CONTAINER_NAME/PG_PORT keep the exact
    # container/port contract (the named container is recreated in place).
    # The data directory lives on tmpfs: this database dies with the run,
    # and keeping postgres's first-boot writes in RAM takes readiness from
    # ~6.7s to ~1s (no fsync I/O). postgres 18 wants the single mount at
    # /var/lib/postgresql — a mount at the retired /var/lib/postgresql/data
    # path makes the image refuse to start.
    if [[ -n ${PG_CONTAINER_NAME:-} ]]; then
      PG_CONTAINER="$PG_CONTAINER_NAME"
      docker rm -fv "$PG_CONTAINER" >/dev/null 2>&1 || true
    else
      PG_CONTAINER="snails-harness-pg-$$"
    fi
    PG_HOST_PORT=""
    if [[ -n ${PG_PORT:-} ]]; then
      PG_HOST_PORT="$PG_PORT"
      PG_PUBLISH="$PG_HOST_PORT:5432"
    else
      PG_PUBLISH="127.0.0.1::5432"
    fi
    docker run -d --name "$PG_CONTAINER" \
      --tmpfs /var/lib/postgresql \
      -e POSTGRES_PASSWORD=postgres -e POSTGRES_DB=integration \
      -p "$PG_PUBLISH" postgres:18-alpine >/dev/null
    if [[ -z $PG_HOST_PORT ]]; then
      PG_HOST_PORT="$(docker port "$PG_CONTAINER" 5432/tcp | head -1 | sed 's/.*://')"
    fi
    export PG_URL="postgres://postgres:postgres@127.0.0.1:$PG_HOST_PORT/integration"
    ready=""
    # 0.2s polls: on tmpfs postgres is ready in ~1s, and the coarse 1s
    # sleep was an average 0.5s of idle wait. A container that died
    # (misconfiguration) ends the wait immediately instead of after the
    # full timeout, with its logs on the existing error path.
    for _ in $(seq 1 100); do
      if psql "$PG_URL" -tAc "SELECT 1" >/dev/null 2>&1; then ready=1; break; fi
      if ! docker inspect -f '{{.State.Running}}' "$PG_CONTAINER" 2>/dev/null | grep -q true; then
        break
      fi
      sleep 0.2
    done
    if [[ -z $ready ]]; then
      echo "[snails] postgres did not start. docker logs:" >&2
      docker logs "$PG_CONTAINER" >&2
      exit 1
    fi
  fi
  # Apply the app's schema (core loader, db/ layout) before boot.
  load_schema
else
  mkdir -p "$SPIN_ROOT/storage"
  export DATABASE_PATH="$SPIN_ROOT/storage/test.sqlite3"
  # Fresh file per suite — leftovers from a previous run would leak into
  # cases that assert row counts.
  rm -f "$DATABASE_PATH" "$DATABASE_PATH-wal" "$DATABASE_PATH-shm"
  load_schema
fi

# Per-run mail capture sink: the server appends to it in test mode and
# the harness reads it back — stale lines from an earlier run would leak
# into this run's log (same rule as the sqlite suite file above).
rm -f "$SPIN_ROOT/tmp/mail-capture.jsonl"

# 4. Boot the server. An explicit PORT is the developer's exact port: a
#    busy one is refused up front (a foreign listener would answer the
#    ready probe and the suite would talk to the wrong server). The
#    default port is picked free per run, and a pick that loses the
#    bind race is retried instead of failing the suite. test.env is
#    SERVER-ONLY (app switches for the boot) — sourced inside the
#    subshell so the test process below keeps a clean ENV; each case
#    sets what it needs, but never the port: the probe and the boot are
#    both pinned to RUNNER_PORT.
if [[ -n $PORT ]]; then
  RUNNER_PORT="$PORT"
  if (echo > /dev/tcp/127.0.0.1/"$RUNNER_PORT") 2>/dev/null; then
    echo "[snails] port $RUNNER_PORT is already in use" >&2
    exit 1
  fi
fi
attempt=0
while :; do
  if [[ -z $RUNNER_PORT ]]; then
    RUNNER_PORT="$(pick_port)" || { echo "[snails] could not find a free port" >&2; exit 1; }
  fi
  (
    cd "$SPIN_ROOT"
    if [[ -f "$HARNESS_DIR/test.env" ]]; then
      set -a
      # shellcheck source=/dev/null
      source "$HARNESS_DIR/test.env"
      set +a
    fi
    # exec: the subshell PID becomes the server. Without it a signal to
    # PID kills the subshell and leaves the server child holding the port.
    PORT="$RUNNER_PORT" exec "$BIN"
  ) >"$LOG" 2>&1 &
  PID=$!
  ready=""
  for _ in $(seq 1 60); do
    if (echo > /dev/tcp/127.0.0.1/"$RUNNER_PORT") 2>/dev/null; then ready=1; break; fi
    # A dead server never opens the port — stop waiting and decide.
    if ! kill -0 "$PID" 2>/dev/null; then break; fi
    sleep 1
  done
  # An open port is not proof that our server is listening — a foreign
  # process on the same port answers the probe too. The binary exits when the
  # bind fails, so liveness is the real check.
  if [[ -n $ready ]] && kill -0 "$PID" 2>/dev/null; then
    break
  fi
  attempt=$(( attempt + 1 ))
  if [[ -n $PORT || $attempt -ge 3 ]]; then
    if [[ -z $ready ]]; then
      fail_with_log "[snails] server did not boot (port closed)" "$LOG"
    else
      fail_with_log "[snails] server exited early (port $RUNNER_PORT taken?)" "$LOG"
    fi
  fi
  kill "$PID" 2>/dev/null || true
  wait "$PID" 2>/dev/null || true
  PID=""
  echo "[snails] port $RUNNER_PORT did not survive boot — retrying on a fresh port" >&2
  RUNNER_PORT=""
done

# 5. Run the harness bundle against the live server.
export APP_BASE_URL="http://127.0.0.1:$RUNNER_PORT"
SPIN_ROOT="$SPIN_ROOT" bash "$ENGINE_DIR/spin-test.sh" "$HARNESS_DIR" ${RUNNER_ARGS[@]+"${RUNNER_ARGS[@]}"}
