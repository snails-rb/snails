#!/bin/bash
# snails small harness — compiles the core under spinel and checks its
# contracts without any consumer app. The expected output is what the bundle
# runner proves about the core graph itself; consumer-side expected outputs
# (bin/native-test etc.) stay separate.
#
# Workspace assembly: harness/fixture (minimal app) + snails-core/ (the
# vendored core —
# the `/up` health controller included) + scaffold seed (the require-all
# files). The workspace PERSISTS under build/test-runtime/ (gitignored
# state): every run mirrors the read-only sources with their mtimes
# intact, so the bundle cache in build/ survives across runs and only a
# changed input forces a recompile. The mirror replaces the tree (minus
# build/ and the generated gen/) instead of merging into it — a source
# file removed from the repo must disappear from the gate too.
#
# The runner is cli/spin-test.sh — the same bundle runner the app
# harness uses: the whole graph is compiled once and each case file runs
# in its own process against its .expected snapshot. `spin test` would
# compile one binary per file (and its mtime cache is all-or-nothing), so
# a one-file change recompiles all of them.
#
# Usage: bash scripts/test-runtime.sh [--pg] [--no-cache] [<case file>...]
#   --pg            run the common fixture tests plus the pg-only group
#                   against a scratch database from PG_URL; skipped when no
#                   server is reachable
#   --no-cache      force a bundle recompile
#   <case file>     run only these case files (a path under the
#                   workspace; unknown names fail, never widen)
# Exit: 0=all cases pass, 1=failure.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../cli/vendor-dir.sh
source "$ROOT/cli/vendor-dir.sh"
# shellcheck source=pg-scratch.sh
source "$ROOT/scripts/pg-scratch.sh"

MODE="sqlite"
if [[ ${1:-} == "--pg" ]]; then
  MODE="pg"
  shift
fi
NO_CACHE=0
CASE_ARGS=()
for arg in "$@"; do
  if [[ $arg == "--no-cache" ]]; then
    NO_CACHE=1
  else
    CASE_ARGS+=("$arg")
  fi
done
RUN_ARGS=()
if (( NO_CACHE == 1 )); then
  RUN_ARGS+=("--no-cache")
fi

# Layering gate: only the boot entry and its profile files may name
# app-contract paths. Every other core file must stay app-free — the
# direction is snails-core/boot.rb -> config/boot.rb ->
# snails-core/boot/*.rb -> app config/database.rb -> backend.
app_refs="$(grep -R -n -E 'require_relative "\.\./+(config|gen|app)/' "$ROOT/runtime" --include='*.rb' | grep -v -F -e "$ROOT/runtime/boot.rb:" -e "$ROOT/runtime/boot/" || true)"
if [[ -n $app_refs ]]; then
  echo "[test-runtime] core files other than the boot entry and profiles must not require app paths:" >&2
  printf '%s\n' "$app_refs" >&2
  exit 1
fi

# Root-namespace gate: core contracts live under an owner namespace.
# `Main` was the last root exception; a reintroduction is a contract regression.
root_main="$(grep -R -n -E '^module Main([^A-Za-z0-9_]|$)' "$ROOT/runtime" "$ROOT/scaffold" "$ROOT/harness/fixture" --include='*.rb' || true)"
if [[ -n $root_main ]]; then
  echo "[test-runtime] root Main namespace is retired — nest it under Snails:" >&2
  printf '%s\n' "$root_main" >&2
  exit 1
fi

# One-line nested module/class declarations hide the nesting boundary and
# force compressed `end; end` tails. Keep each namespace on its own line.
one_line_modules="$(grep -R -n -E '^[[:space:]]*(module|class) [A-Za-z0-9_:]+; (module|class) ' "$ROOT/runtime" "$ROOT/scaffold" "$ROOT/harness/fixture" --include='*.rb' || true)"
if [[ -n $one_line_modules ]]; then
  echo "[test-runtime] one-line nested module/class declarations are not allowed:" >&2
  printf '%s\n' "$one_line_modules" >&2
  exit 1
fi

# The pinned spinel toolchain decides every compile in this gate — the
# same resolver the app engines use (cli/toolchain.sh). The toolchain is
# materialized next to pins.toml, and the PATH's spin is never trusted: a
# stale PATH install once made this gate compile the core with an older
# spinel and report toolchain drift as code errors. spinel_toolchain_env
# is deliberately not used — its repair path runs `snails sync <root>`,
# which is app-tree surgery (the core checkout is not an app). The
# absolute path pin is part of the contract: a relative entry would
# silently fall back after `cd`.
# shellcheck source=toolchain.sh
source "$ROOT/cli/toolchain.sh"
spinel_toolchain_ensure "$ROOT/pins.toml"
TOOLCHAIN_DIR="$(spinel_toolchain_dir "$ROOT/pins.toml")"
export PATH="$TOOLCHAIN_DIR:$PATH"

WORK="$ROOT/build/test-runtime"
if [[ $MODE == "pg" ]]; then
  WORK="$ROOT/build/test-runtime-pg"
fi
mkdir -p "$WORK"

# One run at a time: two runs sharing the build dir would race each
# other's compiles. A lock left by a dead run is taken over.
LOCK="$WORK.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
  holder="$(cat "$LOCK/pid" 2>/dev/null || true)"
  if [[ -n $holder ]] && kill -0 "$holder" 2>/dev/null; then
    echo "[test-runtime] another run (pid $holder) is using $WORK — retry when it finishes" >&2
    exit 1
  fi
  rm -rf "$LOCK"
  mkdir "$LOCK" 2>/dev/null || {
    echo "[test-runtime] could not lock $WORK" >&2
    exit 1
  }
fi
printf '%s\n' "$$" > "$LOCK/pid"
trap 'rm -rf "$LOCK"' EXIT

# Mirror the sources, keeping each file's mtime (what spinel's cache
# reads). Everything but the cache (build/) and the generated require
# lists (gen/) is replaced, so files dropped upstream do not linger.
find "$WORK" -mindepth 1 -maxdepth 1 ! -name build ! -name gen -exec rm -rf {} +
cp -a "$ROOT/harness/fixture/." "$WORK/"
cp -a "$ROOT/runtime" "$WORK/$SNAILS_VENDOR_DIR"

# Copy a shared fixture only when its bytes differ, preserving the source
# mtime. The workspace mirror recreates test/, so the target is new every
# run; a plain cp would stamp it with the current time and the bundle
# runner's mtime boundary would recompile the whole graph every run. The
# source mtime moves when its content changes (git checkout), so the cache
# still invalidates on a real edit.
copy_fixture() {
  local source="$1" target="$2"
  if [[ ! -f $target ]] || ! cmp -s "$source" "$target"; then
    cp -p "$source" "$target"
  fi
}

# scaffold/queue is the shipped DDL template: the queue contract cases
# read it at run time (case processes run with the workspace as their
# cwd), so those tests exercise the exact bytes `generate job_queue` stamps
# into an app instead of a copy of them.
mkdir -p "$WORK/scaffold"
cp -a "$ROOT/scaffold/queue" "$WORK/scaffold/"

# gen/ holds the generator's output (spin-test.sh refreshes it). The seed
# is the template for the first run and is re-seeded only when the seed
# itself changes — copying the seed over generated files every run would
# churn mtimes and defeat the cache.
SEED="$ROOT/scaffold/seed/gen"
if [[ ! -f "$WORK/gen/.seed-stamp" ]] ||
  [[ -n "$(find "$SEED" -newer "$WORK/gen/.seed-stamp" -print -quit)" ]]; then
  rm -rf "$WORK/gen"
  cp -a "$SEED" "$WORK/gen"
  touch "$WORK/gen/.seed-stamp"
fi

cleanup() {
  rm -rf "$LOCK"
}

# The fixture test tree holds common tests plus one directory per adapter.
# Each mode compiles the common tests and its own group; the other group holds
# backend-specific DDL and would fail type-checking against the wrong backend.
if [[ $MODE == "pg" ]]; then
  rm -rf "$WORK/test/sqlite"
  # The app-owned DB config is a shared fixture too: the workspace mirror
  # first copies the fixture's sqlite config, so a plain write here would
  # stamp a new mtime every run and invalidate the bundle cache.
  copy_fixture "$ROOT/scripts/fixtures/database.pg.rb" "$WORK/config/database.rb"

  if ! pg_scratch_available; then
    echo "[test-runtime] skip: no postgres reachable at $PG_ADMIN (pg tests not counted)" >&2
    exit 0
  fi
  if ! pg_scratch_create "snails_runtime_pg"; then
    echo "[test-runtime] could not create scratch database $PG_DB" >&2
    exit 1
  fi
  trap 'pg_scratch_drop; cleanup' EXIT
else
  rm -rf "$WORK/test/pg"
  trap cleanup EXIT
fi

cd "$WORK"
echo "[test-runtime] workspace: $WORK (sources mirrored, build/ reused)"
# `spin` resolves from the pinned toolchain for `spin-test.sh`'s flags
# call — assert it exactly as before.
[[ $(command -v spin) == "$TOOLCHAIN_DIR/spin" ]] || {
  echo "[test-runtime] spin did not resolve to the pinned toolchain: $TOOLCHAIN_DIR/spin" >&2
  exit 1
}
# Interpreter contract: the runner and the CLI engines it calls are shell
# only. A `ruby` that fails loudly shadows PATH for the runner below.
NORUBY="$WORK/.noruby"
mkdir -p "$NORUBY"
cat > "$NORUBY/ruby" <<'SH'
#!/bin/bash
echo "ruby must not be called by the harness runner" >&2
exit 127
SH
chmod +x "$NORUBY/ruby"
# SNAILS_ENV=test mirrors an app's harness test.env: `Snails.env` reads it
# on first use and env_mode_test asserts the mode. The bundle runner compiles
# once and runs each case file in its own process; the CLI is resolved
# through SNAILS_DIR.
if [[ $MODE == "pg" ]]; then
  # Keep the cache case in every selection: its SQL/CACHE trace counts are
  # part of the pg gate contract. The runner still dispatches each selected
  # file in its own process.
  if (( ${#CASE_ARGS[@]} > 0 )); then
    CASE_ARGS=("test/sqlx_request_cache_test.rb" ${CASE_ARGS[@]+"${CASE_ARGS[@]}"})
  fi
  TRACE="$WORK/pg-cache-trace.log"
  set +e
  PATH="$NORUBY:$PATH" SNAILS_ENV=test SPIN_ROOT="$WORK" SNAILS_DIR="$ROOT" PG_URL="$PG_TARGET" RH_SQL_TRACE=1 \
    bash "$ROOT/cli/spin-test.sh" "$WORK" ${RUN_ARGS[@]+"${RUN_ARGS[@]}"} ${CASE_ARGS[@]+"${CASE_ARGS[@]}"} 2> "$TRACE"
  code=$?
  set -e
  if (( code != 0 )); then
    echo "[test-runtime] pg cache trace (failure detail):" >&2
    cat "$TRACE" >&2
    exit "$code"
  fi
  if grep -q 'ruby must not be called by the harness runner' "$TRACE"; then
    echo "[test-runtime] FAIL: the harness runner called ruby" >&2
    exit 1
  fi

  fail=0
  check_count() { # check_count <label> <pattern> <want>
    local got
    got="$(grep -c -- "$2" "$TRACE" || true)"
    if [[ $got != "$3" ]]; then
      echo "[test-runtime] FAIL: $1 (got $got, want $3)" >&2
      fail=1
    else
      echo "[test-runtime] ok: $1 ($got)"
    fi
  }
  check_count "repeat: one execution" "SQL SELECT .*cache_repeat" 1
  check_count "repeat: one replay" "CACHE SELECT .*cache_repeat" 1
  check_count "bind: two values, two executions" "SQL SELECT .*cache_bind" 2
  check_count "bind: repeat is a replay" "CACHE SELECT .*cache_bind" 1
  check_count "write: before and after execute" "SQL SELECT .*cache_write" 2
  check_count "write: nothing replays" "CACHE SELECT .*cache_write" 0
  check_count "thread write: before and after execute" "SQL SELECT .*cache_thread" 2
  check_count "thread write: nothing replays" "CACHE SELECT .*cache_thread" 0
  check_count "outside lease: both execute" "SQL SELECT .*cache_outside" 2
  check_count "outside lease: nothing replays" "CACHE SELECT .*cache_outside" 0
  check_count "nested lease: one execution" "SQL SELECT .*cache_nested" 1
  check_count "nested lease: two replays" "CACHE SELECT .*cache_nested" 2
  check_count "large result: both execute" "SQL SELECT .*cache_large" 2
  check_count "large result: nothing replays" "CACHE SELECT .*cache_large" 0
  check_count "mutate: one execution" "SQL SELECT .*cache_mutate" 1
  check_count "mutate: one replay" "CACHE SELECT .*cache_mutate" 1
  check_count "locking read: both execute" "SQL SELECT .*pg_cache_lock" 2
  check_count "locking read: nothing replays" "CACHE SELECT .*pg_cache_lock" 0
  if (( fail != 0 )); then
    echo "[test-runtime] pg cache trace (failure detail):" >&2
    cat "$TRACE" >&2
  fi
  exit "$fail"
fi

# The sqlite gate runs the common tests plus the sqlite group. The shared
# cache contract stays in every selection so the same trace counts run.
if (( ${#CASE_ARGS[@]} > 0 )); then
  CASE_ARGS=("test/sqlx_request_cache_test.rb" ${CASE_ARGS[@]+"${CASE_ARGS[@]}"})
fi
TRACE="$WORK/sqlite-cache-trace.log"
set +e
PATH="$NORUBY:$PATH" SNAILS_ENV=test SPIN_ROOT="$WORK" SNAILS_DIR="$ROOT" RH_SQL_TRACE=1 \
  bash "$ROOT/cli/spin-test.sh" "$WORK" ${RUN_ARGS[@]+"${RUN_ARGS[@]}"} ${CASE_ARGS[@]+"${CASE_ARGS[@]}"} 2> "$TRACE"
code=$?
set -e
if (( code != 0 )); then
  echo "[test-runtime] sqlite cache trace (failure detail):" >&2
  cat "$TRACE" >&2
  exit "$code"
fi
if grep -q 'ruby must not be called by the harness runner' "$TRACE"; then
  echo "[test-runtime] FAIL: the harness runner called ruby" >&2
  exit 1
fi

fail=0
check_count() { # check_count <label> <pattern> <want>
  local got
  got="$(grep -c -- "$2" "$TRACE" || true)"
  if [[ $got != "$3" ]]; then
    echo "[test-runtime] FAIL: $1 (got $got, want $3)" >&2
    fail=1
  else
    echo "[test-runtime] ok: $1 ($got)"
  fi
}
check_count "repeat: one execution" "SQL SELECT .*cache_repeat" 1
check_count "repeat: one replay" "CACHE SELECT .*cache_repeat" 1
check_count "bind: two values, two executions" "SQL SELECT .*cache_bind" 2
check_count "bind: repeat is a replay" "CACHE SELECT .*cache_bind" 1
check_count "write: before and after execute" "SQL SELECT .*cache_write" 2
check_count "write: nothing replays" "CACHE SELECT .*cache_write" 0
check_count "thread write: before and after execute" "SQL SELECT .*cache_thread" 2
check_count "thread write: nothing replays" "CACHE SELECT .*cache_thread" 0
check_count "outside lease: both execute" "SQL SELECT .*cache_outside" 2
check_count "outside lease: nothing replays" "CACHE SELECT .*cache_outside" 0
check_count "nested lease: one execution" "SQL SELECT .*cache_nested" 1
check_count "nested lease: two replays" "CACHE SELECT .*cache_nested" 2
check_count "large result: both execute" "SQL SELECT .*cache_large" 2
check_count "large result: nothing replays" "CACHE SELECT .*cache_large" 0
check_count "mutate: one execution" "SQL SELECT .*cache_mutate" 1
check_count "mutate: one replay" "CACHE SELECT .*cache_mutate" 1
if (( fail != 0 )); then
  echo "[test-runtime] sqlite cache trace (failure detail):" >&2
  cat "$TRACE" >&2
fi
exit "$fail"
