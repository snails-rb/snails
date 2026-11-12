#!/bin/bash
# Publish the dist for one rev as a GitHub release in the source repository
# (default snails-rb/snails; --dist-repo overrides for a staging fork).
#
# The dist is the unit consumers pin: the core paths (runtime/ cli/
# scaffold/ bin/ pins.toml), LICENSE, and a REV file naming the rev. Both the REV file
# and runtime/snails/version.rb are generated at package time: the latter
# carries `Snails::VERSION`/`Snails::REV`, so the running binary names the
# code it was built from instead of reading the app's pins file at runtime.
#
# Each release carries the dist tarball, its sha256 sidecar, and the rev's
# pins.toml. The release tag is `rev-<full rev>` (GitHub refuses tags that
# are exactly 40 hex characters) and points at that commit, so a SNALS_REV
# pin resolves to exactly one published asset set — and the release is
# immutable: a new rev gets a new release, never a replaced asset.
#
# `--version vX.Y.Z` adds the release channel: after the release is
# published, an annotated version tag is created and pushed at the same
# commit. A version pin (`SNALS_REV="v1.0.0"`) resolves through that tag's
# commit to the rev, whose release carries the assets. Version tags are
# immutable like releases: reusing one would silently retarget every
# consumer pin that names it.
#
# A release reads version-first even though its tag names the rev: the
# title is the version, and the body opens with the pin and the install
# command, followed by the change list since the previous version
# (`--notes-file` replaces the generated body with hand-written notes).
# The tag stays `rev-<rev>` because the assets, the cache path, and the pin
# resolution all key on the rev.
#
# Channel flags make "the recommended install" a property of the release
# instead of of the newest one. A stable version takes Latest; a prerelease
# is marked as one and never takes Latest; an unversioned release
# (`--version` omitted) never takes Latest either — `install.sh` without
# `--rev` then installs the last stable version (or, before the channel
# has one, the newest published release), and an unversioned rev is
# installed by name.
#
# Usage: scripts/publish-dist.sh [rev] [--version vX.Y.Z] [--dry-run] [--out DIR]
#                                 [--notes-file FILE] [--dist-repo OWNER/NAME]
#   rev          commit to publish (default: HEAD); publishing requires it
#                to be on origin/main — a pin must name merged content
#   --version    also create+push the vX.Y.Z release tag at that commit
#                (SemVer: MAJOR breaks, MINOR adds, PATCH fixes; 0.x =
#                development — the API may change until 1.0.0)
#   --notes-file hand-written release body (Markdown) that replaces the
#                generated install lines and change list; the title stays
#   --dry-run    build the assets and the release notes only (no gh, no network)
#   --out DIR    where the assets are written (default: a fresh mktemp -d)
#   --dist-repo  the release repository (default snails-rb/snails); a
#                staging fork must carry the same commits
#
# Assets: snails-dist-<rev>.tar.gz + snails-dist-<rev>.tar.gz.sha256 +
# pins.toml, plus release-notes.md in the output directory. Publishing
# runs from this checkout with the local `gh` auth. CI publishing is not
# wired yet.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# The dist layout a pin restores — the same five paths verify-pin.sh
# checks — plus the generated REV file.
CORE_PATHS=(runtime cli scaffold bin pins.toml LICENSE)

usage() {
  cat <<'USAGE'
usage: publish-dist.sh [rev] [--version vX.Y.Z] [--dry-run] [--out DIR]
                       [--notes-file FILE] [--dist-repo OWNER/NAME]
  rev          commit to publish (default: HEAD; must be on origin/main)
  --version    also create+push the vX.Y.Z release tag at that commit
               (SemVer; 0.x = development, the API may change until 1.0.0)
  --notes-file hand-written release notes that replace the generated body
  --dry-run    build the assets and the release notes only (no gh, no network)
  --out DIR    asset output directory (default: a fresh mktemp -d)
  --dist-repo  the release repository (default snails-rb/snails)
USAGE
}

rev=""
version=""
notes_file=""
dry=0
out=""
dist_repo="snails-rb/snails"
while (($#)); do
  case "$1" in
    --version) version="${2:-}"; shift 2 ;;
    --notes-file) notes_file="${2:-}"; shift 2 ;;
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

# Hand-written notes are an input file: refuse a missing or empty one here,
# before anything is built, and keep an absolute path so a later relative
# resolve cannot pick up a different file.
if [[ -n $notes_file ]]; then
  if [[ ! -f $notes_file ]]; then
    echo "[publish-dist] --notes-file does not exist: $notes_file" >&2
    exit 1
  fi
  if [[ ! -s $notes_file ]]; then
    echo "[publish-dist] --notes-file is empty: $notes_file" >&2
    exit 1
  fi
  notes_file="$(cd "$(dirname "$notes_file")" && pwd)/$(basename "$notes_file")"
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

# The release channel decides both the Latest flag and how the body reads.
# An unversioned publish (no --version) is an unversioned release: a rev no
# version names, reachable by --rev only.
channel=stable
skip_same_base=0
if [[ -z $version ]]; then
  channel=unversioned
elif [[ $version == *-* ]]; then
  channel=prerelease
else
  # A stable release shares its commit with its own last prerelease, so the
  # change list spans the whole version rather than only the candidate.
  skip_same_base=1
fi
if [[ -n $version ]]; then
  release_title="snails $version"
  consumer_pin="$version"
else
  release_title="snails dist ${rev_full:0:12}"
  consumer_pin="$rev_full"
fi

# newer_version <a> <b> — true when the SemVer tag <a> is greater than <b>.
# Both are stable vX.Y.Z forms; each component is compared as a number.
newer_version() {
  local a="${1#v}" b="${2#v}" a1 a2 a3 b1 b2 b3
  IFS=. read -r a1 a2 a3 <<< "$a"
  IFS=. read -r b1 b2 b3 <<< "$b"
  if ((a1 > b1)); then return 0; fi
  if ((a1 < b1)); then return 1; fi
  if ((a2 > b2)); then return 0; fi
  if ((a2 < b2)); then return 1; fi
  ((a3 > b3))
}

# newest_other_stable_tag <exclude> — the greatest local stable version tag
# other than <exclude>. Local tags are the publisher's record of released
# versions (publish creates and pushes them), so a retrospective publish —
# an older version released after a newer one — is caught here without an
# API call. Prints nothing when no other stable tag exists.
newest_other_stable_tag() {
  local exclude="$1" tag best=""
  while read -r tag; do
    [[ $tag == "$exclude" ]] && continue
    [[ $tag == *-* ]] && continue
    if [[ -z $best ]] || newer_version "$tag" "$best"; then
      best="$tag"
    fi
  done < <(git -C "$ROOT" tag --list 'v[0-9]*')
  printf '%s' "$best"
}

# previous_version_tag <rev> <version> <skip_same_base> — the newest v* tag
# reachable from <rev> that is not the version being published. A stable
# release shares its commit with its own last prerelease, so a stable body
# sets skip_same_base=1 and lists changes across the whole version; a
# prerelease skips only itself, so each candidate lists changes since the
# previous one. With no version (an unversioned release) any version tag anchors
# the list. Prints nothing when no version tag is reachable.
previous_version_tag() {
  local rev="$1" version="$2" skip_same_base="$3" base tag best=""
  base="${version%%-*}"
  while read -r tag; do
    if [[ $tag == "$version" ]]; then
      continue
    fi
    if [[ $skip_same_base == 1 && -n $base && ${tag%%-*} == "$base" ]]; then
      continue
    fi
    if git -C "$ROOT" merge-base --is-ancestor "$tag" "$rev" 2>/dev/null; then
      best="$tag"
    fi
  done < <(git -C "$ROOT" tag --list 'v[0-9]*' --sort=v:refname)
  printf '%s' "$best"
}

# GitHub refuses branch/tag names consisting of exactly 40 (or 64) hex
# characters — the tag carries the pin with a fixed prefix instead.
tag="rev-${rev_full}"

# A stable version takes Latest, so releasing an older version after a newer
# one would move the recommended install backwards. Pure git, so a dry run
# catches it too. Older content reaches consumers as an unversioned release
# (no --version) instead.
if [[ $channel == stable ]]; then
  newer="$(newest_other_stable_tag "$version")"
  if [[ -n $newer ]] && newer_version "$newer" "$version"; then
    echo "[publish-dist] $version is older than the published $newer — a stable release takes Latest and would move the recommended install backwards; drop --version for an unversioned release, or publish the newer number" >&2
    exit 1
  fi
fi

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

# The release reads version-first: a title a human can pin-tag by, and a
# body whose first line is the pin to record. `install.sh` without --rev
# installs Latest, so the install line names the rev whenever the channel
# will not hold Latest (a prerelease or an unversioned release).
notes_out="$out/release-notes.md"
if [[ -n $notes_file ]]; then
  cp "$notes_file" "$notes_out"
else
  {
    printf 'Pin: `SNALS_REV="%s"`\n\n' "$consumer_pin"
    if [[ $channel == stable ]]; then
      printf 'Install the latest release:\n\n```sh\ncurl -fsSL https://raw.githubusercontent.com/snails-rb/snails/main/install.sh | bash\n```\n'
    else
      printf 'Install this %s release by its rev (it does not take Latest):\n\n```sh\ncurl -fsSL https://raw.githubusercontent.com/snails-rb/snails/main/install.sh | bash -s -- --rev %s\n```\n' \
        "$channel" "$rev_full"
    fi
    prev="$(previous_version_tag "$rev_full" "$version" "$skip_same_base")"
    printf '\n## Changes\n\n'
    if [[ -n $prev ]]; then
      printf 'Since `%s` (`%s`):\n\n' "$prev" "${rev_full:0:12}"
      git -C "$ROOT" log --no-merges --format='- %s' "$prev..$rev_full"
    else
      printf 'No version tag is reachable — run `git fetch --tags` to anchor this list. Until then the list covers the whole history.\n\n'
      git -C "$ROOT" log --no-merges --format='- %s' "$rev_full"
    fi
    printf '\nReleases are immutable: a rev gets one asset set, never a replaced one. `pins.toml` is the rev'"'"'s spinel declaration; the dist ships only inside the release tarball.\n'
  } > "$notes_out"
fi
echo "[publish-dist] built $notes_out"

if ((dry)); then
  echo "[publish-dist] target repo: $dist_repo"
  echo "[publish-dist] release tag: $tag (dry run — nothing published)"
  echo "[publish-dist] release title: $release_title"
  echo "[publish-dist] channel: $channel (dry run — nothing published)"
  if [[ -n $version ]]; then
    echo "[publish-dist] version tag: $version (dry run — nothing published)"
  fi
  exit 0
fi

release_args=(--repo "$dist_repo" --target "$rev_full"
  --title "$release_title" --notes-file "$notes_out")
case "$channel" in
  stable) release_args+=(--latest) ;;
  # A prerelease never takes Latest on its own; asking for both would be
  # a contradictory request.
  prerelease) release_args+=(--prerelease) ;;
  unversioned) release_args+=(--latest=false) ;;
esac
gh release create "$tag" "$out/$asset" "$out/$asset.sha256" "$out/pins.toml" \
  "${release_args[@]}"
echo "[publish-dist] published $(gh release view "$tag" --repo "$dist_repo" --json url --jq .url)"
echo "[publish-dist] consumers pin: SNALS_REV=\"$consumer_pin\" ($channel channel)"
if [[ $channel == stable ]]; then
  echo "[publish-dist] install.sh without --rev now installs this release (Latest)"
else
  echo "[publish-dist] Latest stays on the last stable release — install this rev with 'install.sh --rev $rev_full'"
fi

# The version tag comes after the release: a version pin must resolve to
# a release that already exists. It points at the same commit, so the pin
# resolves through the tag to the rev whose release carries the assets.
if [[ -n $version ]]; then
  git -C "$ROOT" tag -a "$version" "$rev_full" -m "snails $version"
  git -C "$ROOT" push origin "refs/tags/$version"
  echo "[publish-dist] version tag $version -> ${rev_full:0:12}"
  echo "[publish-dist] next: bash install.sh, then rerun the app gate without SNAILS_DIR (the installed CLI must carry this rev)"
fi
