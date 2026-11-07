#!/bin/bash
# Install the snails CLI from the published dist releases.
#
#   curl -fsSL https://raw.githubusercontent.com/snails-rb/dist/main/install.sh | bash
#
# The script downloads the dist for the latest release (or a rev you
# name), verifies its sha256 sidecar, unpacks it under
# <SNAILS_HOME>/dist/<rev>, and links <SNAILS_BIN_DIR>/snails to it. The
# CLI is self-contained: `snails new` vendors the pinned core from the
# same dist. Re-run to upgrade; remove the dist directory and the symlink
# to uninstall.
#
# Usage: install.sh [--rev <full-rev>]
#
# Environment:
#   SNAILS_DIST_BASE_URL  asset base URL (default: the repo's releases)
#   SNAILS_HOME           install root (default ~/.local/share/snails)
#   SNAILS_BIN_DIR        symlink location (default ~/.local/bin)
set -euo pipefail

REPO="snails-rb/dist"
SNAILS_HOME="${SNAILS_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/snails}"
SNAILS_BIN_DIR="${SNAILS_BIN_DIR:-$HOME/.local/bin}"
BASE="${SNAILS_DIST_BASE_URL:-https://github.com/$REPO/releases/download}"

usage() {
  cat <<'USAGE'
usage: install.sh [--rev <full-rev>]
  --rev <rev>   install a specific full rev instead of the latest release
USAGE
}

rev=""
while (($#)); do
  case "$1" in
    --rev) rev="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "[snails] unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

command -v curl >/dev/null 2>&1 || { echo "[snails] curl is required" >&2; exit 1; }
command -v tar >/dev/null 2>&1 || { echo "[snails] tar is required" >&2; exit 1; }

# download_asset <tag> <asset> <out> — fetch one release asset from the
# public release repo.
download_asset() {
  local tag="$1" asset="$2" out="$3"
  curl -fsSL -o "$out" "$BASE/$tag/$asset"
}
sha256_check() {
  local dir="$1" file="$2"
  if command -v sha256sum >/dev/null 2>&1; then
    (cd "$dir" && sha256sum -c "$file")
  else
    (cd "$dir" && shasum -a 256 -c "$file")
  fi
}

# Latest release via the API: the tag names the rev to install.
if [[ -z $rev ]]; then
  body="$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest")" || {
    echo "[snails] could not resolve the latest release of $REPO — pass --rev <full-rev>" >&2
    exit 1
  }
  tag="$(printf '%s' "$body" | sed -n 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p')"
  rev="${tag#rev-}"
fi
if [[ ! $rev =~ ^[0-9a-f]{40}$ ]]; then
  echo "[snails] '$rev' is not a full 40-hex rev" >&2
  exit 1
fi

dest="$SNAILS_HOME/dist/$rev"
asset="snails-dist-$rev.tar.gz"

if [[ -f $dest/REV && $(<"$dest/REV") == "$rev" ]]; then
  echo "[snails] dist $rev already installed at $dest"
else
  tmp="$dest.tmp.$$"
  rm -rf "$tmp"
  mkdir -p "$tmp"
  echo "[snails] downloading dist $rev" >&2
  download_asset "rev-$rev" "$asset" "$tmp/$asset" || { rm -rf "$tmp"; echo "[snails] dist download failed for $rev" >&2; exit 1; }
  download_asset "rev-$rev" "$asset.sha256" "$tmp/$asset.sha256" || { rm -rf "$tmp"; echo "[snails] checksum download failed for $rev" >&2; exit 1; }
  if ! sha256_check "$tmp" "$asset.sha256" >/dev/null; then
    rm -rf "$tmp"
    echo "[snails] checksum mismatch — refusing the download" >&2
    exit 1
  fi
  tar -xzf "$tmp/$asset" -C "$tmp"
  rm -f "$tmp/$asset" "$tmp/$asset.sha256"
  if [[ ! -f $tmp/REV || $(<"$tmp/REV") != "$rev" ]]; then
    rm -rf "$tmp"
    echo "[snails] the downloaded dist does not carry REV=$rev" >&2
    exit 1
  fi
  mkdir -p "$(dirname "$dest")"
  rm -rf "$dest"
  mv "$tmp" "$dest"
  echo "[snails] dist $rev -> $dest"
fi

mkdir -p "$SNAILS_BIN_DIR"
ln -sfn "$dest/bin/snails" "$SNAILS_BIN_DIR/snails"
echo "[snails] linked $SNAILS_BIN_DIR/snails -> $dest/bin/snails"

case ":$PATH:" in
  *":$SNAILS_BIN_DIR:"*) ;;
  *) echo "[snails] note: $SNAILS_BIN_DIR is not on PATH — add it to use the snails command" ;;
esac

echo "[snails] ready — create a project: snails new <dir>"
echo "[snails] tip: 'snails install-shim' adds spin/spinel shims that follow each project's pinned toolchain"
