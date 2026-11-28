#!/bin/bash
# Install the snails CLI from the source repository's published dist releases.
#
#   curl -fsSL https://raw.githubusercontent.com/snails-rb/snails/main/install.sh | bash
#
# The script downloads the dist for the latest release (a version, or an
# edge rev), verifies its sha256 sidecar, unpacks it under
# <SNAILS_HOME>/dist/<version-or-rev>, and links <SNAILS_BIN_DIR>/snails to
# it. The CLI is self-contained: `snails new` vendors the pinned core from
# the same dist. Re-run to upgrade; remove the dist directory and the
# symlink to uninstall.
#
# The default install resolves Latest through the release page redirect and
# the releases feed, not the REST API; the API is a last resort for the
# default channel and the legacy version tag, and SNAILS_GITHUB_TOKEN raises
# its rate limit.
#
# Usage: install.sh [--version <vX.Y.Z>] [--rev <full-rev>]
#
# Environment:
#   SNAILS_RELEASES_BASE_URL  release page base (default: the repo's releases)
#   SNAILS_DIST_BASE_URL      asset base URL (default: <release page>/download)
#   SNAILS_API_BASE_URL       API base URL (default: the repo's GitHub API)
#   SNAILS_HOME               install root (default ~/.local/share/snails)
#   SNAILS_BIN_DIR            symlink location (default ~/.local/bin)
#   SNAILS_GITHUB_TOKEN       API token — raises the release-API rate limit only
set -euo pipefail

REPO="snails-rb/snails"
SNAILS_HOME="${SNAILS_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/snails}"
SNAILS_BIN_DIR="${SNAILS_BIN_DIR:-$HOME/.local/bin}"
RELEASES="${SNAILS_RELEASES_BASE_URL:-https://github.com/$REPO/releases}"
RELEASES="${RELEASES%/}"
BASE="${SNAILS_DIST_BASE_URL:-$RELEASES/download}"
API="${SNAILS_API_BASE_URL:-https://api.github.com/repos/$REPO}"
DIST_TAG_RE='^(v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?|rev-[0-9a-f]{40})$'

usage() {
  cat <<'USAGE'
usage: install.sh [--version <vX.Y.Z>] [--rev <full-rev>]
  --version <version>  install a specific release version (stable or rc)
  --rev <rev>          install a full-rev edge release instead of the latest
USAGE
}

version=""
rev=""
while (($#)); do
  case "$1" in
    --version) version="${2:-}"; shift 2 ;;
    --rev) rev="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "[snails] unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done
if [[ -n $version && -n $rev ]]; then
  echo "[snails] pass either --version or --rev, not both" >&2
  usage >&2
  exit 2
fi
if [[ -n $version && ! $version =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]]; then
  echo "[snails] '$version' is not a vX.Y.Z version — pass a release version, or --rev <full-rev>" >&2
  exit 1
fi
if [[ -n $rev && ! $rev =~ ^[0-9a-f]{40}$ ]]; then
  echo "[snails] '$rev' is not a full 40-hex rev — pass the value of 'git rev-parse HEAD' in the snails checkout" >&2
  exit 1
fi

command -v curl >/dev/null 2>&1 || { echo "[snails] curl is required — install it and rerun" >&2; exit 1; }
command -v tar >/dev/null 2>&1 || { echo "[snails] tar is required — install it and rerun" >&2; exit 1; }

# download_asset <tag> <asset> <out> — fetch one release asset from the
# source repository.
# GitHub's release endpoint answers a transient 5xx or 429 under load; the
# first command a new user runs should not stop there. --retry covers those
# and connection failures, and leaves a 404 as the final answer. The
# timeouts keep an unreachable host from hanging the install.
download_asset() {
  local tag="$1" asset="$2" out="$3"
  curl -fsSL --retry 3 --retry-delay 1 --retry-connrefused \
    --connect-timeout 10 --max-time 300 -o "$out" "$BASE/$tag/$asset"
}
# The REST API answers unauthenticated and shares the IP's 60/hour budget
# with everything else on it. It is the last resort for the default channel
# and the legacy tag resolution; the release page and feed carry the normal
# latest lookup. A CI runner behind a shared address can exhaust that
# budget, so SNAILS_GITHUB_TOKEN is accepted here; the assets are public and
# are fetched without the header. The same transient errors apply.
api_get() {
  local url="$1"
  local retry=(--retry 3 --retry-delay 1 --retry-connrefused --connect-timeout 10 --max-time 300)
  if [[ -n ${SNAILS_GITHUB_TOKEN:-} ]]; then
    curl -fsSL "${retry[@]}" -H "Authorization: Bearer $SNAILS_GITHUB_TOKEN" "$url"
  else
    curl -fsSL "${retry[@]}" "$url"
  fi
}
sha256_check() {
  local dir="$1" file="$2"
  if command -v sha256sum >/dev/null 2>&1; then
    (cd "$dir" && sha256sum -c "$file")
  else
    (cd "$dir" && shasum -a 256 -c "$file")
  fi
}
# packaged_version <dir> — the VERSION constant in an unpacked dist, or
# empty when the metadata is missing.
packaged_version() {
  sed -n 's/^  VERSION = "\(.*\)"/\1/p' "$1/runtime/snails/version.rb" 2>/dev/null | head -n1
}
# dist_matches <dir> <version> <rev> — true when <dir> is already the dist
# this install asks for: its packaged version names the requested version,
# or its REV names the requested rev.
dist_matches() {
  local dir="$1" want_version="$2" want_rev="$3"
  [[ -f $dir/REV && $(<"$dir/REV") =~ ^[0-9a-f]{40}$ ]] || return 1
  if [[ -n $want_version ]]; then
    [[ "$(packaged_version "$dir")" == "$want_version" ]] || return 1
  elif [[ -n $want_rev && $(<"$dir/REV") != "$want_rev" ]]; then
    return 1
  fi
  return 0
}
# dist_tag_from_json <body> — the first dist tag in a release JSON document,
# newest first. A dist release is a version tag or an edge `rev-<40hex>`;
# toolchain releases (`spinel-rev-…`) are not dist pins.
dist_tag_from_json() {
  printf '%s' "$1" | grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' \
    | sed 's/.*"\([^"]*\)"$/\1/' \
    | grep -E "$DIST_TAG_RE" \
    | head -n1
}
# is_dist_tag <tag> — true when the tag names a dist release: a version or
# an edge rev.
is_dist_tag() {
  [[ $1 =~ $DIST_TAG_RE ]]
}
# dist_tag_from_redirect — the tag the release page's Latest redirect lands
# on. The page redirect is a web endpoint; it does not spend the REST API's
# unauthenticated budget, which shared CI runner IPs exhaust.
dist_tag_from_redirect() {
  local effective tag
  effective="$(curl -fsSIL --retry 3 --retry-delay 1 --retry-connrefused \
    --connect-timeout 10 --max-time 30 -o /dev/null -w '%{url_effective}' \
    "$RELEASES/latest")" || return 1
  case "$effective" in
    */tag/*) tag="${effective##*/}" ;;
    *) return 1 ;;
  esac
  is_dist_tag "$tag" || return 1
  printf '%s\n' "$tag"
}
# dist_tag_from_atom — the first dist tag in the releases feed. The feed
# carries every release, including prereleases and toolchain releases; the
# first dist tag is the newest one. It covers a channel with no stable
# release, where the Latest redirect has no tag.
dist_tag_from_atom() {
  local atom
  atom="$(curl -fsSL --retry 3 --retry-delay 1 --retry-connrefused \
    --connect-timeout 10 --max-time 30 "$RELEASES.atom")" || return 1
  printf '%s' "$atom" \
    | grep -o 'tag:github\.com,2008:Repository/[0-9]*/[^<]*' \
    | sed 's#.*Repository/[0-9]*/##' \
    | grep -E "$DIST_TAG_RE" \
    | head -n1
}
# resolve_version_rev <version> — the commit a version tag names. A
# version-keyed release tags the release with the version; a version
# published before that layout tags a commit whose rev release carries the
# artifact. A lightweight tag names its commit directly, an annotated tag
# through its tag object.
resolve_version_rev() {
  local version="$1" json sha type
  json="$(api_get "$API/git/ref/tags/$version")" || return 1
  sha="$(printf '%s' "$json" | tr -d '[:space:]' | sed -n 's/.*"object":{[^}]*"sha":"\([0-9a-f]\{40\}\)".*/\1/p')"
  type="$(printf '%s' "$json" | tr -d '[:space:]' | sed -n 's/.*"object":{[^}]*"type":"\([a-z]*\)".*/\1/p')"
  case "$type" in
    commit)
      printf '%s' "$sha"
      ;;
    tag)
      json="$(api_get "$API/git/tags/$sha")" || return 1
      sha="$(printf '%s' "$json" | tr -d '[:space:]' | sed -n 's/.*"object":{[^}]*"sha":"\([0-9a-f]\{40\}\)".*/\1/p')"
      type="$(printf '%s' "$json" | tr -d '[:space:]' | sed -n 's/.*"object":{[^}]*"type":"\([a-z]*\)".*/\1/p')"
      [[ $type == "commit" ]] || return 1
      printf '%s' "$sha"
      ;;
    *)
      return 1
      ;;
  esac
}

# The default install follows the Latest release, whose tag names the pin.
# The release page redirect carries the stable Latest without the REST API;
# a fresh channel has no stable release yet, so the releases feed's first
# dist tag stands in. The API remains a last resort for both, with a token.
tag=""
if [[ -n $version ]]; then
  tag="$version"
elif [[ -n $rev ]]; then
  tag="rev-$rev"
else
  tag="$(dist_tag_from_redirect || true)"
  if [[ -z $tag ]]; then
    tag="$(dist_tag_from_atom || true)"
  fi
  if [[ -z $tag ]]; then
    body="$(api_get "$API/releases/latest")" || body=""
    tag="$(dist_tag_from_json "$body" || true)"
    if [[ -z $tag ]]; then
      body="$(api_get "$API/releases?per_page=100")" || body=""
      tag="$(dist_tag_from_json "$body" || true)"
    fi
    if [[ -z $body ]]; then
      echo "[snails] could not find a release for $REPO — check your network, or pass --version <vX.Y.Z> / --rev <full-rev>" >&2
      exit 1
    fi
    if [[ -z $tag ]]; then
      echo "[snails] could not find a dist release for $REPO — check the release channel, or pass --version <vX.Y.Z> / --rev <full-rev>" >&2
      exit 1
    fi
  fi
fi

key=""
want_version=""
want_rev=""
if [[ $tag == rev-* ]]; then
  want_rev="${tag#rev-}"
  if [[ ! $want_rev =~ ^[0-9a-f]{40}$ ]]; then
    echo "[snails] '$tag' does not name a full 40-hex rev — check the release tag" >&2
    exit 1
  fi
  key="$want_rev"
elif [[ $tag == v* ]]; then
  want_version="$tag"
  key="$want_version"
else
  echo "[snails] '$tag' is neither a version release nor an edge rev release — check the release channel" >&2
  exit 1
fi

dest="$SNAILS_HOME/dist/$key"
asset="snails-dist-$key.tar.gz"

if dist_matches "$dest" "$want_version" "$want_rev"; then
  echo "[snails] dist $key already installed at $dest"
else
  tmp="$dest.tmp.$$"
  rm -rf "$tmp"
  mkdir -p "$tmp"
  echo "[snails] downloading dist $key" >&2
  fetch_tag="$tag"
  fetch_asset="$asset"
  if ! download_asset "$fetch_tag" "$fetch_asset" "$tmp/$fetch_asset"; then
    if [[ -z $want_version ]]; then
      rm -rf "$tmp"
      echo "[snails] could not download the dist for $key — release $tag has no $asset; check the release and your network" >&2
      exit 1
    fi
    # A version published before version-keyed releases has no asset under
    # its own tag; the rev release that names the same artifact carries it.
    legacy_rev="$(resolve_version_rev "$want_version" || true)"
    if [[ -z $legacy_rev ]]; then
      rm -rf "$tmp"
      echo "[snails] could not download the dist for $key — release $tag has no $asset, and its tag names no revision; check the release and your network" >&2
      exit 1
    fi
    fetch_tag="rev-$legacy_rev"
    fetch_asset="snails-dist-$legacy_rev.tar.gz"
    want_rev="$legacy_rev"
    echo "[snails] release $tag has no version asset — using legacy release $fetch_tag" >&2
    if ! download_asset "$fetch_tag" "$fetch_asset" "$tmp/$fetch_asset"; then
      rm -rf "$tmp"
      echo "[snails] could not download the dist for $key — neither release $tag nor legacy release $fetch_tag is reachable" >&2
      exit 1
    fi
  fi
  if ! download_asset "$fetch_tag" "$fetch_asset.sha256" "$tmp/$fetch_asset.sha256"; then
    rm -rf "$tmp"
    echo "[snails] could not download the checksum for $key — release $fetch_tag has no $fetch_asset.sha256" >&2
    exit 1
  fi
  if ! sha256_check "$tmp" "$fetch_asset.sha256" >/dev/null; then
    rm -rf "$tmp"
    echo "[snails] checksum mismatch — delete the cached dist and retry; if it repeats, the release is corrupt" >&2
    exit 1
  fi
  tar -xzf "$tmp/$fetch_asset" -C "$tmp"
  rm -f "$tmp/$fetch_asset" "$tmp/$fetch_asset.sha256"
  if [[ ! -f $tmp/REV || ! $(<"$tmp/REV") =~ ^[0-9a-f]{40}$ ]]; then
    rm -rf "$tmp"
    echo "[snails] the downloaded dist carries no full revision — the release is corrupt; delete the cached dist and retry" >&2
    exit 1
  fi
  if [[ -n $want_version && "$(packaged_version "$tmp")" != "$want_version" ]]; then
    rm -rf "$tmp"
    echo "[snails] the downloaded dist names version '$(packaged_version "$tmp")', not $want_version — the release asset is mis-stamped" >&2
    exit 1
  fi
  if [[ -n $want_rev && $(<"$tmp/REV") != "$want_rev" ]]; then
    rm -rf "$tmp"
    echo "[snails] the downloaded dist is for another revision — delete the cached dist and retry" >&2
    exit 1
  fi
  mkdir -p "$(dirname "$dest")"
  rm -rf "$dest"
  mv "$tmp" "$dest"
  echo "[snails] dist $key -> $dest"
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
