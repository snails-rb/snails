#!/bin/bash
# Build the native binary on this host with the pinned toolchain.
#
# Engine for `snails build-binary`; the app's bin/build-binary is a thin
# wrapper. Use this when deploying without a container runtime (systemd, a
# tarball). The image path uses `snails build-image` instead; both compile
# the same tree.
#
# Usage: cli/build-binary.sh [<repo_root>]
set -euo pipefail

ENGINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SNAILS_ROOT="$(cd "$ENGINE_DIR/.." && pwd)"
SNAILS_CLI="$SNAILS_ROOT/bin/snails"
# shellcheck source=app-root.sh
source "$ENGINE_DIR/app-root.sh"
# shellcheck source=generators.sh
source "$ENGINE_DIR/generators.sh"

if [[ ${1:-} == "-h" || ${1:-} == "--help" ]]; then
  echo "usage: snails build-binary [<repo_root>]"
  exit 0
fi

ROOT="${1:-$PWD}"
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

# A build compiles the core that its declared source provides: `pin`
# restores SNALS_REV, while `checkout` takes the working tree as it stands,
# including uncommitted changes. The vendored copy records the source it
# came from. An unknown value still fails with a clear error, so a typo
# never selects a source silently.
pins_source "$pins_file" "[snails]" >/dev/null || exit 1

APP_NAME="$(pins_get "$pins_file" APP_NAME "[snails]")" || exit 1
: "${APP_NAME:?pins.toml is missing APP_NAME}"

"$SNAILS_CLI" sync "$APP_ROOT" >/dev/null
run_generators "$SNAILS_CLI" "$APP_ROOT"

(cd "$APP_ROOT" && "$SNAILS_CLI" exec spin build)
[[ -x "$APP_ROOT/build/bin/$APP_NAME" ]] || {
  echo "[snails] spin build did not produce build/bin/$APP_NAME" >&2
  exit 1
}
mkdir -p "$APP_ROOT/build"
cp "$APP_ROOT/build/bin/$APP_NAME" "$APP_ROOT/build/$APP_NAME"
chmod +x "$APP_ROOT/build/$APP_NAME"

echo "[snails] binary ready: $APP_ROOT/build/$APP_NAME"
