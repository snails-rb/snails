#!/bin/bash
# Render the README demo. The pinned compiler and the first app build are
# warmed outside the recording, so the GIF shows the daily loop instead of
# the two-minute compile.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

for tool in vhs ttyd ffmpeg snails; do
  command -v "$tool" >/dev/null || {
    echo "render-demo: $tool is required — install vhs and ttyd with 'mise install aqua:charmbracelet/vhs aqua:tsl0922/ttyd' (or 'brew install vhs ttyd'), and put snails on PATH" >&2
    exit 1
  }
done

snails new "$work/warm" >/dev/null
rm -rf "$work/warm"

cp "$root/demo/demo.tape" "$work/"
cd "$work"
vhs demo.tape
mv demo.gif "$root/demo/demo.gif"
