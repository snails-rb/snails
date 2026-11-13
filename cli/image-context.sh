# Image build-context staging: the single source for the extra inputs the
# app Dockerfile uses beyond the app's own files.
#
# The image carries the snails CLI so `docker compose run app snails migrate
# …` works by name. The engines stage the whole bin/ and cli/ tree into the
# app's gitignored build/ directory before `docker build`; the stage is
# generated, refreshed on every build, and added back to .dockerignore. A
# file list would drift whenever the CLI's internal requires change, and
# that failure appears only inside the container, which the host tests never
# exercise. db/migrate/ gets the same treatment: the Dockerfile COPYs it,
# and an app with no migrations yet has no such directory (git does not
# track empty dirs, which is why the engine creates it).
#
# The stage lives outside snails-core/ on purpose: that directory is an
# exact copy of the pinned core, and build inputs are not core content.
#
# Sourced only — defines a function, executes nothing.
# shellcheck shell=bash

# stage_image_context <app_root> — put every non-app input the Dockerfile
# COPYs into <app_root>: build/image-context/snails/{bin,cli} (removed and
# staged fresh, so a renamed CLI file cannot linger) and db/migrate/.
stage_image_context() { # <app_root>
  local app_root="$1" cli_root dst
  cli_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  dst="$app_root/build/image-context/snails"
  rm -rf "$dst"
  mkdir -p "$dst" "$app_root/db/migrate"
  cp -R "$cli_root/bin" "$cli_root/cli" "$dst/"
}
