#!/bin/bash
# Consumer install smoke: the published release channel to a booted app.
#
# This runs the path a new user takes, and nothing from the checkout: install
# the CLI with the documented one-liner, create a project with the installed
# dist, load the schema, run the project's harness, and boot the dev server
# against GET /up. SNAILS_DIR is refused and the resolved CLI must live under
# SNAILS_HOME, so a green run cannot be a source-mode run by accident.
#
# The caller owns the packages: install only what the requirements docs list.
# A superset hides a missing dependency the docs promise (platform-ci's macOS
# job passes gnu-sed and coreutils for the repo scripts, for example).
#
# Usage: bash scripts/release-smoke.sh [--rev <full-rev>] [--keep]
#   --rev <rev>  expected revision — the install must resolve to it
#   --keep       keep the work directory and print its path
#
# Environment:
#   SNAILS_INSTALL_URL   installer URL (default: the documented raw URL)
#   SNAILS_HOME          install root (default: <work>/snails-home)
#   SNAILS_BIN_DIR       symlink directory (default: <work>/bin)
#   SNAILS_GITHUB_TOKEN  API token — raises the API rate limit; assets are public
#
# Exit: 0=pass, 1=failure, 2=usage.
set -uo pipefail

INSTALL_URL="${SNAILS_INSTALL_URL:-https://raw.githubusercontent.com/snails-rb/snails/main/install.sh}"
EXPECTED_REV=""
KEEP=""

usage() {
  cat <<'USAGE'
usage: bash scripts/release-smoke.sh [--rev <full-rev>] [--keep]
  --rev <rev>  expected revision — the install must resolve to it
  --keep       keep the work directory and print its path
USAGE
}

while (($#)); do
  case "$1" in
    --rev)
      [[ $# -ge 2 && -n $2 ]] || {
        echo "[release-smoke] --rev needs a value" >&2
        usage >&2
        exit 2
      }
      EXPECTED_REV="$2"
      shift 2
      ;;
    --keep) KEEP=1; shift ;;
    -h | --help) usage; exit 0 ;;
    *)
      echo "[release-smoke] unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

[[ -z $EXPECTED_REV || $EXPECTED_REV =~ ^[0-9a-f]{40}$ ]] || {
  echo "[release-smoke] --rev must be a full 40-hex revision: '$EXPECTED_REV'" >&2
  exit 2
}
# A checkout CLI makes every step below source-mode, which is the path this
# smoke exists to contrast with. Refuse it before any work starts.
[[ -z ${SNAILS_DIR:-} ]] || {
  echo "[release-smoke] SNAILS_DIR is set ($SNAILS_DIR) — the smoke must use the installed CLI; unset it and rerun" >&2
  exit 1
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/snails-release-smoke.XXXXXX")"
SNAILS_HOME="${SNAILS_HOME:-$WORK/snails-home}"
SNAILS_BIN_DIR="${SNAILS_BIN_DIR:-$WORK/bin}"
export SNAILS_HOME SNAILS_BIN_DIR
# First on PATH: the installer links into this directory, and the app's
# bin/test and bin/dev resolve the CLI through `command -v snails`.
export PATH="$SNAILS_BIN_DIR:$PATH"

STAGE_N=0
STAGE_TOTAL=6
STAGE="start"
DEV_PID=""

cleanup() {
  local rc=$?
  if [[ -n $DEV_PID ]]; then
    kill "$DEV_PID" 2>/dev/null || true
    wait "$DEV_PID" 2>/dev/null || true
  fi
  if ((rc == 0)); then
    if [[ -n $KEEP ]]; then
      echo "[release-smoke] work directory: $WORK"
    else
      rm -rf "$WORK"
    fi
    return 0
  fi
  echo "[release-smoke] FAILED at step $STAGE_N/$STAGE_TOTAL: $STAGE" >&2
  if [[ -n $EXPECTED_REV ]]; then
    echo "[release-smoke] reproduce: bash scripts/release-smoke.sh --rev $EXPECTED_REV" >&2
  else
    echo "[release-smoke] reproduce: bash scripts/release-smoke.sh" >&2
  fi
  if [[ -n $KEEP ]]; then
    echo "[release-smoke] work directory kept at $WORK" >&2
  else
    echo "[release-smoke] add --keep to inspect the work directory" >&2
  fi
}
trap cleanup EXIT

stage() {
  STAGE_N=$((STAGE_N + 1))
  STAGE="$1"
  echo "[release-smoke] step $STAGE_N/$STAGE_TOTAL: $1"
}

fail() {
  echo "[release-smoke] $*" >&2
  exit 1
}

# 1. The documented installer command, piped to the system bash. Running the
#    checkout copy of install.sh would skip the pipe path the manual shows.
stage "install the CLI from the published channel"
install_log="$WORK/install.log"
if ! curl -fsSL "$INSTALL_URL" | bash >"$install_log" 2>&1; then
  cat "$install_log" >&2
  fail "the installer failed: $INSTALL_URL"
fi

# 2. The installer resolves the channel; this step proves what it resolved.
#    Reaching the app through the symlink is the whole point — a checkout CLI
#    or a stale cached dist must not pass.
stage "assert the installed dist (not the checkout)"
target="$(readlink "$SNAILS_BIN_DIR/snails" 2>/dev/null || true)"
case "$target" in
  "$SNAILS_HOME"/dist/*/bin/snails) ;;
  *) fail "the snails symlink does not point into $SNAILS_HOME/dist: '${target}'" ;;
esac
dist="${target%/bin/snails}"
rev="$(cat "$dist/REV" 2>/dev/null || true)"
[[ $rev =~ ^[0-9a-f]{40}$ ]] || fail "no full revision in $dist/REV (got '$rev')"
if [[ -n $EXPECTED_REV && $rev != "$EXPECTED_REV" ]]; then
  fail "the install resolved $rev, expected $EXPECTED_REV — the channel moved or the API answered an older release"
fi
version="$(snails version 2>&1 || true)"
[[ $version == *"rev ${rev:0:7}"* ]] || fail "'snails version' does not name the installed revision: '$version'"
echo "[release-smoke] installed: $version"

# 3. The installed dist scaffolds from its own tree (REV file, no .git).
stage "create a --scaffold project with the installed CLI"
app="$WORK/app"
snails new "$app" --scaffold >"$WORK/new.log" 2>&1 || {
  cat "$WORK/new.log" >&2
  fail "the installed CLI could not scaffold a project"
}

# 4. A scaffolded project ships the baseline as a migration only; load is the
#    documented setup step and what bin/dev expects.
stage "load the schema"
snails migrate load --app "$app" >"$WORK/load.log" 2>&1 || {
  cat "$WORK/load.log" >&2
  fail "migrate load failed"
}

# 5. The project's own gate: build, boot, and the scaffold's CRUD cases. The
#    case count is not asserted — a case count is not a contract. The exit
#    status is: a failed build must stop here, not fall through to the dev
#    step and report its own missing binary. --verbose is what prints a failed
#    load's log; without it CI only gets the path to a file the job deletes.
stage "run the project harness (bin/test)"
"$app/bin/test" --verbose || fail "the project harness (bin/test) failed"

# 6. bin/dev is a foreground server. The port is picked free here so a foreign
#    listener cannot answer the readiness probe.
stage "boot bin/dev and answer GET /up"
port=""
for _ in $(seq 1 60); do
  candidate=$((49152 + RANDOM % 16384))
  if (echo >/dev/tcp/127.0.0.1/"$candidate") 2>/dev/null; then continue; fi
  port="$candidate"
  break
done
[[ -n $port ]] || fail "no free port for the dev server"
dev_log="$WORK/dev.log"
PORT="$port" "$app/bin/dev" --skip-build >"$dev_log" 2>&1 &
DEV_PID=$!
up=""
for _ in $(seq 1 60); do
  if ! kill -0 "$DEV_PID" 2>/dev/null; then break; fi
  if curl -fsS "http://127.0.0.1:$port/up" >"$WORK/up.json" 2>/dev/null; then
    up=1
    break
  fi
  sleep 1
done
if [[ -z $up ]]; then
  cat "$dev_log" >&2
  fail "the dev server did not answer GET /up on port $port"
fi
grep -q '"status":"ok"' "$WORK/up.json" || {
  cat "$WORK/up.json" >&2
  fail "GET /up did not answer the health payload"
}
kill "$DEV_PID" 2>/dev/null || true
wait "$DEV_PID" 2>/dev/null || true
DEV_PID=""
# The wrappers exec all the way down, so one kill stops the server; a live
# binary here means a forked child outlived its parent.
if command -v pgrep >/dev/null 2>&1 && pgrep -f "$app/build/bin/" >/dev/null 2>&1; then
  pkill -f "$app/build/bin/" 2>/dev/null || true
  fail "the dev server outlived its own stop ($app/build/bin)"
fi

echo "[release-smoke] PASS (rev $rev)"
