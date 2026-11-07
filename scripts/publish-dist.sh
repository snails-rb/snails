#!/bin/bash
# Publish the dist for one rev as a GitHub release on the public
# release repo (default snails-rb/dist; --dist-repo overrides).
#
# The dist is the unit consumers pin: the core paths (runtime/ cli/
# scaffold/ bin/ pins.toml), LICENSE, and a REV file naming the rev. Both the REV file
# and runtime/snails/version.rb are generated at package time: the latter
# carries `Snails::VERSION`/`Snails::REV`, so the running binary names the
# code it was built from instead of reading the app's pins file at runtime.
#
# The repo's main carries install.sh (the curl entry point, synced here
# from this checkout); each release carries the dist tarball, its sha256
# sidecar, and the rev's pins.toml. The release channel is separate from
# the source repository. The release tag is `rev-<full rev>` (GitHub
# refuses tags that are exactly 40 hex characters), so a SNALS_REV pin
# resolves to exactly one published asset set — and the release is
# immutable: a new rev gets a new release, never a replaced asset.
#
# `--version vX.Y.Z` adds the release channel: after the release is
# published, an annotated version tag is created and pushed at the same
# commit in this checkout, and a second annotated tag is created in the
# repo. That repo has no source commits, so its
# tag points at the release-target commit and carries `REV=<full rev>` in
# the message — that is how an installed CLI maps a version pin back to the
# source rev. Version tags are immutable like releases: reusing one would
# silently retarget every consumer pin that names it.
#
# Usage: scripts/publish-dist.sh [rev] [--version vX.Y.Z] [--dry-run] [--out DIR]
#                                 [--dist-repo OWNER/NAME]
#   rev          commit to publish (default: HEAD); publishing requires it
#                to be on origin/main — a pin must name merged content
#   --version    also create+push the vX.Y.Z release tag at that commit
#                (SemVer: MAJOR breaks, MINOR adds, PATCH fixes; 0.x =
#                development — the API may change until 1.0.0)
#   --dry-run    build the assets only (no gh, no network)
#   --out DIR    where the assets are written (default: a fresh mktemp -d)
#   --dist-repo  the public release repo (default snails-rb/dist)
#
# Assets: snails-dist-<rev>.tar.gz + snails-dist-<rev>.tar.gz.sha256 +
# pins.toml. Publishing runs from this checkout with the local `gh` auth.
# CI publishing is not wired yet.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# The dist layout a pin restores — the same five paths verify-pin.sh
# checks — plus the generated REV file.
CORE_PATHS=(runtime cli scaffold bin pins.toml LICENSE)

usage() {
  cat <<'USAGE'
usage: publish-dist.sh [rev] [--version vX.Y.Z] [--dry-run] [--out DIR]
                        [--dist-repo OWNER/NAME]
  rev          commit to publish (default: HEAD; must be on origin/main)
  --version    also create+push the vX.Y.Z release tag at that commit
               (SemVer; 0.x = development, the API may change until 1.0.0)
  --dry-run    build the assets only (no gh, no network)
  --out DIR    asset output directory (default: a fresh mktemp -d)
  --dist-repo  the public release repo (default snails-rb/dist)
USAGE
}

rev=""
version=""
dry=0
out=""
dist_repo="snails-rb/dist"
while (($#)); do
  case "$1" in
    --version) version="${2:-}"; shift 2 ;;
    --dry-run) dry=1; shift ;;
    --out) out="${2:-}"; shift 2 ;;
    --dist-repo) dist_repo="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "[publish-dist] unknown flag: $1" >&2; exit 2 ;;
    *) rev="$1"; shift ;;
  esac
done
[[ -n $rev ]] || rev="HEAD"
if [[ ! $dist_repo =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
  echo "[publish-dist] --dist-repo must look like owner/name, got: $dist_repo" >&2
  exit 1
fi

rev_full="$(git -C "$ROOT" rev-parse --verify "${rev}^{commit}" 2>/dev/null)" || {
  echo "[publish-dist] unknown rev: $rev" >&2
  exit 1
}

# The version must be a release name consumers can pin — the same shape
# the CLI's pin gate accepts (a v before three numbers, optional
# prerelease), rejected here so a typo never becomes an immutable tag.
if [[ -n $version && ! $version =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]]; then
  echo "[publish-dist] --version must look like v0.1.0 (SemVer with a v prefix), got: $version" >&2
  exit 1
fi

# GitHub refuses branch/tag names consisting of exactly 40 (or 64) hex
# characters — the tag carries the pin with a fixed prefix instead.
tag="rev-${rev_full}"

if ((dry == 0)); then
  # A published rev must be merged content: consumers resolve their pin
  # to this release, so anything but origin/main is unpublished work.
  if ! git -C "$ROOT" merge-base --is-ancestor "$rev_full" refs/remotes/origin/main; then
    echo "[publish-dist] ${rev_full:0:12} is not on origin/main — merge and push it first" >&2
    exit 1
  fi
  # A version tag is a consumer-facing pin name: never reuse one. Local
  # ref first, then origin (another machine may have pushed it) — pure
  # git checks, before gh so a bad version refuses without the API.
  if [[ -n $version ]]; then
    if git -C "$ROOT" show-ref --verify --quiet "refs/tags/$version"; then
      echo "[publish-dist] tag $version already exists — version tags are immutable; bump the version" >&2
      exit 1
    fi
    if git -C "$ROOT" ls-remote --exit-code --tags origin "refs/tags/$version" >/dev/null 2>&1; then
      echo "[publish-dist] tag $version already exists on origin — version tags are immutable; bump the version" >&2
      exit 1
    fi
  fi
  command -v gh >/dev/null 2>&1 || { echo "[publish-dist] gh is required to publish" >&2; exit 1; }
  if ! gh api "repos/$dist_repo" --jq .full_name >/dev/null 2>&1; then
    echo "[publish-dist] repo $dist_repo is not reachable with this gh login — create it (public, no README) or check access" >&2
    exit 1
  fi
  if gh release view "$tag" --repo "$dist_repo" >/dev/null 2>&1; then
    echo "[publish-dist] release $tag already exists in $dist_repo — releases are immutable; publish the next rev" >&2
    exit 1
  fi
  if [[ -n $version ]] && gh api "repos/$dist_repo/git/ref/tags/$version" >/dev/null 2>&1; then
    echo "[publish-dist] tag $version already exists in $dist_repo — version tags are immutable; bump the version" >&2
    exit 1
  fi
fi

# Every dist path must exist in the rev: a partial dist would be vendored
# as a broken tree, so the miss is loud here instead.
for p in "${CORE_PATHS[@]}"; do
  if ! git -C "$ROOT" cat-file -e "$rev_full:$p" 2>/dev/null; then
    echo "[publish-dist] ${rev_full:0:12} does not carry $p — not a dist rev" >&2
    exit 1
  fi
done

if [[ -z $out ]]; then
  out="$(mktemp -d)"
fi
mkdir -p "$out"
asset="snails-dist-${rev_full}.tar.gz"
stage="$(mktemp -d "${TMPDIR:-/tmp}/snails-dist-stage.XXXXXX")"
trap 'rm -rf "$stage"' EXIT

# The artifact carries its own version metadata. The version label is the
# release tag when one is being created, otherwise the full rev; the exact
# rev is always the full commit.
git -C "$ROOT" archive --format=tar "$rev_full" -- "${CORE_PATHS[@]}" | tar -x -C "$stage"
printf '%s\n' "$rev_full" > "$stage/REV"
version_value="${version:-$rev_full}"
version_file="$stage/runtime/snails/version.rb"
if [[ ! -f $version_file ]]; then
  echo "[publish-dist] ${rev_full:0:12} does not carry runtime/snails/version.rb — not a version-bearing dist" >&2
  exit 1
fi
awk -v version="$version_value" -v rev="$rev_full" '
  /^[[:space:]]*VERSION = / { print "  VERSION = \"" version "\""; next }
  /^[[:space:]]*REV = /     { print "  REV = \"" rev "\""; next }
  { print }
' "$version_file" > "$version_file.tmp"
mv "$version_file.tmp" "$version_file"
if ! grep -Fqx "  VERSION = \"$version_value\"" "$version_file" ||
   ! grep -Fqx "  REV = \"$rev_full\"" "$version_file"; then
  echo "[publish-dist] could not stamp $version_file — the rev's metadata shape changed" >&2
  exit 1
fi
tar -cf "$out/dist.tar" -C "$stage" "${CORE_PATHS[@]}" REV
# The release publishes the rev's pin file as its own asset:
# an installed CLI reads the pair record from the release, not from a
# source tree it does not have.
cp "$stage/pins.toml" "$out/pins.toml"
rm -rf "$stage"
gzip -n -9 -c "$out/dist.tar" > "$out/$asset"
rm -f "$out/dist.tar"

# sha256sum is GNU; shasum covers macOS. The file keeps the
# `<hash>  <name>` line format so the same bytes serve mise's
# checksum_url and the CLI's own verification.
if command -v sha256sum >/dev/null 2>&1; then
  (cd "$out" && sha256sum "$asset" > "$asset.sha256")
else
  (cd "$out" && shasum -a 256 "$asset" > "$asset.sha256")
fi

echo "[publish-dist] built $out/$asset"
echo "[publish-dist] built $out/$asset.sha256"
echo "[publish-dist] built $out/pins.toml"

if ((dry)); then
  echo "[publish-dist] target repo: $dist_repo"
  echo "[publish-dist] release tag: $tag (dry run — nothing published)"
  if [[ -n $version ]]; then
    echo "[publish-dist] version tag: $version (dry run — nothing published)"
  fi
  exit 0
fi

# The repo carries no source tree; its main branch holds the
# curl entry point only. Keep that copy identical to this checkout's, so a
# consumer never installs with a stale default repo or an old flag set.
# Creating the file also creates main on a fresh, empty repo.
sync_install() {
  local repo="$1" rev="$2" remote sha content
  local -a args
  remote="$(mktemp)"
  sha="$(gh api "repos/$repo/contents/install.sh" --jq .sha 2>/dev/null || true)"
  if [[ -n $sha ]]; then
    if ! gh api "repos/$repo/contents/install.sh" -H "Accept: application/vnd.github.raw" > "$remote" 2>/dev/null; then
      rm -f "$remote"
      echo "[publish-dist] could not read $repo/install.sh" >&2
      return 1
    fi
    if cmp -s "$remote" "$ROOT/install.sh"; then
      rm -f "$remote"
      return 0
    fi
  fi
  rm -f "$remote"
  content="$(base64 < "$ROOT/install.sh" | tr -d '\n')"
  args=(-X PUT "repos/$repo/contents/install.sh"
    -f message="sync install.sh from ${rev:0:12}"
    -f content="$content"
    -f branch=main)
  [[ -n $sha ]] && args+=(-f sha="$sha")
  if ! gh api "${args[@]}" >/dev/null; then
    echo "[publish-dist] could not sync install.sh to $repo" >&2
    return 1
  fi
  echo "[publish-dist] synced install.sh -> $repo"
}

sync_install "$dist_repo" "$rev_full" || exit 1
if ! dist_main="$(gh api "repos/$dist_repo/commits/main" --jq .sha 2>/dev/null)"; then
  echo "[publish-dist] $dist_repo has no main commit — the install.sh sync must create it" >&2
  exit 1
fi

subject="$(git -C "$ROOT" log -1 --format='%s' "$rev_full")"
# The version is the pin a release channel recommends; the full rev stays
# the temporary edge form for a pre-release test.
if [[ -n $version ]]; then
  consumer_pin="$version"
else
  consumer_pin="$rev_full"
fi
notes="snails dist at $rev_full.

$subject

A consumer pin (SNALS_REV=\"$consumer_pin\") resolves to this release. Releases are immutable: a new rev gets a new release, never a replaced asset. pins.toml is the rev's spinel declaration; install.sh lives on main and the code ships only inside the dist tarball."
gh release create "$tag" "$out/$asset" "$out/$asset.sha256" "$out/pins.toml" \
  --repo "$dist_repo" \
  --target "$dist_main" \
  --title "dist ${rev_full:0:12}" \
  --notes "$notes"
echo "[publish-dist] published $(gh release view "$tag" --repo "$dist_repo" --json url --jq .url)"
if [[ -z $version ]]; then
  echo "[publish-dist] consumers pin: SNALS_REV=\"$rev_full\""
fi

# The version tag comes after the release: a version pin must resolve to
# a release that already exists, so the alias is only created once its
# asset set is live. The repo's tag is the dist-mode mapping:
# it points at the release target and names the source rev in its message.
if [[ -n $version ]]; then
  dist_tag_object="$(gh api -X POST "repos/$dist_repo/git/tags" \
    -f tag="$version" \
    -f message="snails $version REV=$rev_full" \
    -f object="$dist_main" \
    -f type=commit --jq .sha 2>/dev/null)" || dist_tag_object=""
  if [[ -z $dist_tag_object ]] || ! gh api -X POST "repos/$dist_repo/git/refs" \
    -f ref="refs/tags/$version" -f sha="$dist_tag_object" >/dev/null; then
    echo "[publish-dist] release $tag is published but the $dist_repo version tag $version failed — create it before consumers pin $version" >&2
    exit 1
  fi
  git -C "$ROOT" tag -a "$version" "$rev_full" -m "snails $version"
  git -C "$ROOT" push origin "refs/tags/$version"
  echo "[publish-dist] version tag $version -> ${rev_full:0:12} (source and $dist_repo) — consumers pin: SNALS_REV=\"$version\""
  echo "[publish-dist] next: bash install.sh, then rerun the app gate without SNAILS_DIR (the installed CLI must carry this rev)"
fi
