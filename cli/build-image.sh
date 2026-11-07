#!/bin/bash
# Build the app image from the pinned core and the published spinel image.
#
# Engine for `snails build-image`; the app's bin/build-image is a thin
# wrapper. The core is not committed (snails-core/ is generated), so this
# script vendors the pin first. It skips the toolchain materialization: the
# compile runs inside the published spinel image, not on this host.
#
# Usage: cli/build-image.sh [<repo_root>] [--platform ...] [--tag TAG]
#   IMAGE  image repository (default: the app name, lowercased)
#   TAG    image tag (default: local)
set -euo pipefail

ENGINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SNAILS_ROOT="$(cd "$ENGINE_DIR/.." && pwd)"
SNAILS_CLI="$SNAILS_ROOT/bin/snails"
# shellcheck source=app-root.sh
source "$ENGINE_DIR/app-root.sh"
# shellcheck source=generators.sh
source "$ENGINE_DIR/generators.sh"

ROOT="$PWD"
if (($#)) && [[ $1 != -* ]]; then
  ROOT="$1"
  shift
fi

usage() {
  cat <<'USAGE'
usage: snails build-image [<repo_root>] [--platform linux/amd64|linux/arm64] [--tag TAG]
  IMAGE  image repository (default: the app name, lowercased)
  TAG    image tag (default: local)
USAGE
}

platform="${PLATFORM:-}"
tag="${TAG:-local}"
while (($#)); do
  case "$1" in
    --platform) platform="${2:-}"; shift 2 ;;
    --tag) tag="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "[snails] unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -d $ROOT ]] || { echo "[snails] repo root not found: $ROOT" >&2; exit 1; }
ROOT="$(cd "$ROOT" && pwd)"

# The app root is the repo root, or src/ when the app lives there — the
# shared rule (cli/app-root.sh), the same one every caller-named directory
# argument gets. SPINEL_SRC overrides it.
APP_ROOT="${SPINEL_SRC:-$(app_root_for "$ROOT")}"
[[ -d $APP_ROOT ]] || { echo "[snails] app root not found: $APP_ROOT" >&2; exit 1; }
APP_ROOT="$(cd "$APP_ROOT" && pwd)"

if "$SNAILS_CLI" verify-pins -h >/dev/null 2>&1; then
  "$SNAILS_CLI" verify-pins "$APP_ROOT" >/dev/null || exit 1
fi

# shellcheck source=pins.sh
source "$ENGINE_DIR/pins.sh"

# Parse the pins file instead of sourcing it (pins are declarations, never
# shell code), and discover it with the same walk verify-pins uses so the
# verified file and the read file are always the same one.
pins_file="$(pins_discover "$APP_ROOT")"
[[ -n $pins_file ]] || { echo "[snails] no pins file at or above $APP_ROOT — add pins.toml (snails new stamps one)" >&2; exit 1; }
SPINEL_REV="$(pins_get "$pins_file" SPINEL_REV "[snails]")" || exit 1
SNALS_REV="$(pins_get "$pins_file" SNALS_REV "[snails]")" || exit 1
APP_NAME="$(pins_get "$pins_file" APP_NAME "[snails]")" || exit 1
: "${SPINEL_REV:?pins.toml is missing SPINEL_REV}"
: "${SNALS_REV:?pins.toml is missing SNALS_REV}"
: "${APP_NAME:?pins.toml is missing APP_NAME}"

# A build compiles the core its declared source provides — "pin" restores
# SNALS_REV, "checkout" takes the working tree as it stands, uncommitted
# changes included; the vendored copy records that itself. An unknown
# value still fails loudly, so a typo never picks a source silently.
pins_source "$pins_file" "[snails]" >/dev/null || exit 1

# The image build consumes the pinned core from the context. Check first so a
# current tree does not churn file mtimes and invalidate the Docker cache.
if ! "$SNAILS_CLI" sync --check --skip-toolchain "$APP_ROOT" >/dev/null 2>&1; then
  echo "[snails] core is missing or stale — syncing the pinned core" >&2
  "$SNAILS_CLI" sync --skip-toolchain "$APP_ROOT" >/dev/null
fi

# gen/* is refreshed before the context is read (cli/generators.sh): the
# Dockerfile compiles whatever the context carries, so a tree whose gen/* is
# stale would bake a stale require list into the image. Content-gated, so an
# unchanged tree keeps its mtimes and the cache above holds.
run_generators "$SNAILS_CLI" "$APP_ROOT"

# The Dockerfile COPYs the snails CLI and db/migrate from the context —
# stage them now (see cli/image-context.sh), after sync and the gen/*
# refresh so the context carries the current tree.
# shellcheck source=image-context.sh
source "$ENGINE_DIR/image-context.sh"
stage_image_context "$APP_ROOT"
command -v docker >/dev/null || {
  echo "[snails] docker not found — install Docker, or use your platform's builder" >&2
  exit 1
}

image="${IMAGE:-$(printf '%s' "$APP_NAME" | tr '[:upper:]' '[:lower:]')}"
if [[ ! $image =~ ^[a-z0-9]+([._/-][a-z0-9]+)*$ ]]; then
  echo "[snails] '$image' is not a valid image repository — set IMAGE=<repository>" >&2
  exit 1
fi

DOCKERFILE="${DOCKERFILE:-}"
if [[ -z $DOCKERFILE ]]; then
  if [[ -f "$ROOT/Dockerfile" ]]; then
    DOCKERFILE="$ROOT/Dockerfile"
  elif [[ -f "$ROOT/deploy/spinel/Dockerfile" ]]; then
    DOCKERFILE="$ROOT/deploy/spinel/Dockerfile"
  elif [[ -f "$APP_ROOT/Dockerfile" ]]; then
    DOCKERFILE="$APP_ROOT/Dockerfile"
  else
    echo "[snails] Dockerfile not found — expected $ROOT/Dockerfile, $ROOT/deploy/spinel/Dockerfile, or $APP_ROOT/Dockerfile" >&2
    exit 1
  fi
fi
if [[ -z ${CONTEXT:-} ]]; then
  if [[ "$DOCKERFILE" == "$APP_ROOT/Dockerfile" && "$APP_ROOT" != "$ROOT" ]]; then
    CONTEXT="$APP_ROOT"
  else
    CONTEXT="$ROOT"
  fi
fi

args=(--build-arg "SPINEL_REV=$SPINEL_REV" --build-arg "SNALS_REV=$SNALS_REV" --build-arg "APP_NAME=$APP_NAME")

if [[ -n $platform ]]; then
  docker buildx build --platform "$platform" --load -f "$DOCKERFILE" -t "$image:$tag" "${args[@]}" "$CONTEXT"
elif docker buildx version >/dev/null 2>&1; then
  docker buildx build --load -f "$DOCKERFILE" -t "$image:$tag" "${args[@]}" "$CONTEXT"
else
  DOCKER_BUILDKIT=1 docker build -f "$DOCKERFILE" -t "$image:$tag" "${args[@]}" "$CONTEXT"
fi

echo "[snails] image ready: $image:$tag"
# shellcheck source=database-adapter.sh
source "$ENGINE_DIR/database-adapter.sh"
adapter="$(database_adapter_for "$APP_ROOT" 2>/dev/null || true)"
if [[ $adapter == "pg" ]]; then
  echo "[snails] next: docker run --rm -p 3000:3000 -e PG_URL=... $image:$tag"
else
  echo "[snails] next: docker run --rm -p 3000:3000 -v app_storage:/snails/storage $image:$tag"
fi
