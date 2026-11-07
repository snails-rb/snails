#!/bin/bash
# End-to-end image contract: a new app builds its image and serves GET /up.
#
# Also covers the src/ app-root layout: the repo-root build scripts detect
# src/pins.toml, build the image from src/Dockerfile, build the binary, and
# read the compose file next to the app.
#
# Requires docker and the published spinel image for the current pin. A
# missing image fails with the publish hint instead of falling back to a
# source build — the image contract is what this test checks.
#
# Usage: bash scripts/test-image.sh
# Exit: 0=pass, 1=failure, 0 with a skip line when docker is absent.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLI="$ROOT/bin/snails"
WORK="$(mktemp -d)"
NAME="snails-test-image-$$"
VOLUME="snails-test-image-$$-storage"
IMAGE_NAME="snails-test-image-$$"
SRC_NAME="snails-test-image-$$-src"
SRC_VOLUME="snails-test-image-$$-src-storage"
SRC_IMAGE_NAME="snails-test-image-$$-src"
TAG="test"
IMAGE="$IMAGE_NAME:$TAG"
SRC_IMAGE="$SRC_IMAGE_NAME:$TAG"

cleanup() {
  docker rm -f "$NAME" "$SRC_NAME" >/dev/null 2>&1 || true
  docker volume rm "$VOLUME" "$SRC_VOLUME" >/dev/null 2>&1 || true
  docker image rm "$IMAGE" "$SRC_IMAGE" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

wait_for_up() {
  local name="$1" label="$2" up=""
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    if up="$(docker exec "$name" curl -fsS http://127.0.0.1:3000/up 2>/dev/null)"; then
      break
    fi
    sleep 1
  done
  if [[ $up != *'"status":"ok"'* ]]; then
    docker logs "$name" >&2
    fail "$label"
  fi
}

command -v docker >/dev/null || { echo "[test-image] docker not found — image test skipped"; exit 0; }

# shellcheck source=/dev/null
source "$ROOT/pins.toml"
docker manifest inspect "ghcr.io/snails-rb/spinel:$SPINEL_REV" >/dev/null 2>&1 \
  || fail "spinel image missing for SPINEL_REV=$SPINEL_REV — publish it first"

SNAILS_DIR="$ROOT" "$CLI" new "$WORK/app" >"$WORK/new.log" 2>&1 || {
  cat "$WORK/new.log" >&2
  fail "snails new"
}
# Build args — a rollout of any declared source is a normal build. The
# generated app's declaration is the checkout source, which builds the core
# working tree as it stands; the version metadata marks that.
SNAILS_DIR="$ROOT" IMAGE="$IMAGE_NAME" "$WORK/app/bin/build-image" --tag "$TAG" >"$WORK/build.log" 2>&1 || {
  cat "$WORK/build.log" >&2
  fail "bin/build-image"
}
docker run -d --name "$NAME" -p "127.0.0.1::3000" -v "$VOLUME:/snails/storage" "$IMAGE" >/dev/null \
  || fail "docker run"
wait_for_up "$NAME" "GET /up"

# The image's default command is the app, and the migration runner is on
# PATH: the documented one-off form (`docker compose run … snails migrate …`)
# must work without an entrypoint shim.
docker run --rm "$IMAGE" snails migrate status >/dev/null \
  || fail "in-image migration runner (snails migrate status)"

# src/ layout: the repo root has bin/build-*, the app root is src/.
SRC_REPO="$WORK/repo"
mkdir -p "$SRC_REPO/bin"
SNAILS_DIR="$ROOT" "$CLI" new "$SRC_REPO/src" >"$WORK/new-src.log" 2>&1 || {
  cat "$WORK/new-src.log" >&2
  fail "snails new (src layout)"
}
cp "$ROOT/scaffold/new/bin/build-image" "$SRC_REPO/bin/build-image"
cp "$ROOT/scaffold/new/bin/build-binary" "$SRC_REPO/bin/build-binary"
cp "$ROOT/scaffold/new/bin/compose" "$SRC_REPO/bin/compose"
chmod +x "$SRC_REPO/bin/build-image" "$SRC_REPO/bin/build-binary" "$SRC_REPO/bin/compose"

SNAILS_DIR="$ROOT" IMAGE="$SRC_IMAGE_NAME" "$SRC_REPO/bin/build-image" --tag "$TAG" >"$WORK/build-src.log" 2>&1 || {
  cat "$WORK/build-src.log" >&2
  fail "src-layout bin/build-image"
}
docker run -d --name "$SRC_NAME" -p "127.0.0.1::3000" -v "$SRC_VOLUME:/snails/storage" "$SRC_IMAGE" >/dev/null \
  || fail "src-layout docker run"
wait_for_up "$SRC_NAME" "src-layout GET /up"

SNAILS_DIR="$ROOT" "$SRC_REPO/bin/build-binary" >"$WORK/build-binary-src.log" 2>&1 || {
  cat "$WORK/build-binary-src.log" >&2
  fail "src-layout bin/build-binary"
}
[[ -x "$SRC_REPO/src/build/src" ]] || fail "src-layout bin/build-binary did not write src/build/src"

SNAILS_DIR="$ROOT" "$SRC_REPO/bin/compose" config >"$WORK/compose-src.log" 2>&1 || {
  cat "$WORK/compose-src.log" >&2
  fail "src-layout bin/compose config"
}

echo "[test-image] ok: $IMAGE and the src layout serve GET /up"
