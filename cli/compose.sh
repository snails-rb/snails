#!/bin/bash
# Run Docker Compose with the pinned core and the app image.
#
# Engine for `snails compose`; the app's bin/compose is a thin wrapper. The
# compose file builds the same Dockerfile as `snails build-image`. This
# engine exports the pins as build args and vendors snails-core/ first.
#
# Usage: cli/compose.sh [<repo_root>] [-- <docker compose args>...]
set -euo pipefail

ENGINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SNAILS_ROOT="$(cd "$ENGINE_DIR/.." && pwd)"
SNAILS_CLI="$SNAILS_ROOT/bin/snails"
# shellcheck source=app-root.sh
source "$ENGINE_DIR/app-root.sh"

if [[ ${1:-} == "-h" || ${1:-} == "--help" ]]; then
  echo "usage: snails compose [<repo_root>] [-- <docker compose args>...]"
  exit 0
fi

ROOT="$PWD"
if (($#)) && [[ $1 != -* ]]; then
  ROOT="$1"
  shift
fi
if [[ ${1:-} == "--" ]]; then
  shift
fi
[[ -d $ROOT ]] || { echo "[snails] repo root not found: $ROOT" >&2; exit 1; }
ROOT="$(cd "$ROOT" && pwd)"

# The app root is the repository root, or src/ when the app lives there.
# This is the shared rule (cli/app-root.sh) that applies to every
# caller-named directory argument. SPINEL_SRC overrides it.
APP_ROOT="${SPINEL_SRC:-$(app_root_for "$ROOT")}"
[[ -d $APP_ROOT ]] || { echo "[snails] app root not found: $APP_ROOT" >&2; exit 1; }
APP_ROOT="$(cd "$APP_ROOT" && pwd)"

if "$SNAILS_CLI" verify-pins -h >/dev/null 2>&1; then
  "$SNAILS_CLI" verify-pins "$APP_ROOT" >/dev/null || exit 1
fi

# shellcheck source=pins.sh
source "$ENGINE_DIR/pins.sh"

# Parse the pins file instead of sourcing it (pins are declarations, never
# shell code). Discover it with the same walk verify-pins uses, so the file
# that was verified is always the file that gets read.
pins_file="$(pins_discover "$APP_ROOT")"
[[ -n $pins_file ]] || { echo "[snails] no pins file at or above $APP_ROOT — add pins.toml (snails new stamps one)" >&2; exit 1; }
SPINEL_REV="$(pins_get "$pins_file" SPINEL_REV "[snails]")" || exit 1
SNALS_REV="$(pins_get "$pins_file" SNALS_REV "[snails]")" || exit 1
APP_NAME="$(pins_get "$pins_file" APP_NAME "[snails]")" || exit 1
: "${SPINEL_REV:?pins.toml is missing SPINEL_REV}"
: "${SNALS_REV:?pins.toml is missing SNALS_REV}"
: "${APP_NAME:?pins.toml is missing APP_NAME}"

# A build compiles the core that its declared source provides: `pin`
# restores SNALS_REV, while `checkout` takes the working tree as it stands,
# including uncommitted changes. The vendored copy records the source it
# came from. An unknown value still fails with a clear error, so a typo
# never selects a source silently.
pins_source "$pins_file" "[snails]" >/dev/null || exit 1

COMPOSE_FILE="$ROOT/compose.yml"
[[ -f $COMPOSE_FILE ]] || COMPOSE_FILE="$APP_ROOT/compose.yml"
[[ -f $COMPOSE_FILE ]] || {
  echo "[snails] compose.yml not found — restore it (snails new creates it)" >&2
  exit 1
}

# The sqlite recipe bind-mounts ./storage, so create it as the calling user
# first: otherwise Docker creates it owned by root, the container (running
# as PUID:PGID) cannot write to it, and it restarts in a loop at boot.
# shellcheck source=database-adapter.sh
source "$ENGINE_DIR/database-adapter.sh"
adapter="$(database_adapter_for "$APP_ROOT")" || exit 1
if [[ $adapter == "sqlite" ]]; then
  mkdir -p "$(dirname "$COMPOSE_FILE")/storage"
fi

if ! "$SNAILS_CLI" sync --check --skip-toolchain "$APP_ROOT" >/dev/null 2>&1; then
  echo "[snails] core is missing or stale — syncing the pinned core" >&2
  "$SNAILS_CLI" sync --skip-toolchain "$APP_ROOT" >/dev/null
fi

# The Dockerfile COPYs the snails CLI and db/migrate from the context —
# stage them now (see cli/image-context.sh), after sync so the vendored
# core dir exists.
# shellcheck source=image-context.sh
source "$ENGINE_DIR/image-context.sh"
stage_image_context "$APP_ROOT"

command -v docker >/dev/null || {
  echo "[snails] docker not found — install Docker with the Compose plugin" >&2
  exit 1
}
docker compose version >/dev/null 2>&1 || {
  echo "[snails] docker compose not found — install the Compose plugin" >&2
  exit 1
}

export SPINEL_REV SNALS_REV APP_NAME
app_image="$(printf '%s' "$APP_NAME" | tr '[:upper:]' '[:lower:]')"
if [[ ! $app_image =~ ^[a-z0-9]+([._/-][a-z0-9]+)*$ ]]; then
  echo "[snails] '$app_image' is not a valid image repository — set APP_IMAGE=<repository:tag>" >&2
  exit 1
fi
export APP_IMAGE="${APP_IMAGE:-$app_image:local}"

cd "$(dirname "$COMPOSE_FILE")"
exec docker compose -f "$COMPOSE_FILE" "$@"
