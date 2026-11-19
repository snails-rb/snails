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
# Each release carries the dist tarball, its sha256 sidecar, and the
# release's pins.toml. The release tag names the pin. A versioned publish
# (`--version vX.Y.Z`) tags the release with the version, so an rc and its
# stable can sit on the same commit with separate, correctly stamped
# assets; an unversioned publish tags the release `rev-<full rev>` (GitHub
# refuses tags that are exactly 40 hex characters) for the edge channel.
# Each release is immutable: a new pin name gets a new release, never a
# replaced asset.
#
# A version pin (`SNALS_REV="v1.2.0"`) resolves through the release tag
# directly: the pin and the asset address are one name. Version tags are
# immutable like releases: reusing one would silently retarget every
# consumer pin that names it.
#
# A release reads version-first: the title is the version (or the rev for
# an edge release), and the body opens with the pin and the install
# command, followed by the change list since the previous version
# (`--notes-file` replaces the generated body with hand-written notes).
#
# Channel flags make "the recommended install" a property of the release
# instead of the newest one. A stable version takes Latest; a prerelease
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
#   --version    publish a version release: the release tag is the version
#                (SemVer: MAJOR breaks, MINOR adds, PATCH fixes; 0.x =
#                development — the API may change until 1.0.0). A stable
#                version takes Latest; a prerelease does not.
#   --notes-file hand-written release body (Markdown) that replaces the
#                generated install lines and change list; the title stays
#   --dry-run    build the assets and the release notes only (no gh, no network)
#   --out DIR    where the assets are written (default: a fresh mktemp -d)
#   --dist-repo  the release repository (default snails-rb/snails); a
#                staging fork must carry the same commits
#
# Assets: snails-dist-<version>.tar.gz (or snails-dist-<rev>.tar.gz for an
# edge release) + its .sha256 + pins.toml, plus release-notes.md in the
# output directory. Publishing runs from this checkout with the local `gh`
# auth. CI publishing is not wired yet.
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

# The version must be a release name consumers can pin — the same form
# the CLI's pin gate accepts (a v before three numbers, optional
# prerelease). It is rejected here so a typo never becomes an immutable tag.
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
  # The stable body spans the whole version: skip every candidate tag of the
  # same base (vX.Y.Z-rc.N) so the list starts at the previous version.
  skip_same_base=1
fi
if [[ -n $version ]]; then
  release_title="snails $version"
  consumer_pin="$version"
else
  release_title="snails dist ${rev_full:0:12}"
  consumer_pin="$rev_full"
fi

# semver_newer <a> <b> — true when the v-prefixed version <a> outranks <b>
# under SemVer precedence. Git's v:refname sort puts a release's candidates
# after it, so tag order cannot decide which version is newer. The numeric core
# is compared first; a release outranks its candidates; prerelease identifiers
# follow SemVer rules, where a numeric identifier compares as a number and
# outranks a non-numeric one.
semver_newer() {
  local a="${1#v}" b="${2#v}" a_core b_core a_pre="" b_pre=""
  if [[ $a == *-* ]]; then
    a_core="${a%%-*}"
    a_pre="${a#*-}"
  else
    a_core="$a"
  fi
  if [[ $b == *-* ]]; then
    b_core="${b%%-*}"
    b_pre="${b#*-}"
  else
    b_core="$b"
  fi

  local a1 a2 a3 b1 b2 b3
  IFS=. read -r a1 a2 a3 <<< "$a_core"
  IFS=. read -r b1 b2 b3 <<< "$b_core"
  if ((10#$a1 > 10#$b1)); then return 0; fi
  if ((10#$a1 < 10#$b1)); then return 1; fi
  if ((10#$a2 > 10#$b2)); then return 0; fi
  if ((10#$a2 < 10#$b2)); then return 1; fi
  if ((10#$a3 > 10#$b3)); then return 0; fi
  if ((10#$a3 < 10#$b3)); then return 1; fi

  if [[ -z $a_pre && -z $b_pre ]]; then return 1; fi
  if [[ -z $a_pre ]]; then return 0; fi
  if [[ -z $b_pre ]]; then return 1; fi

  local -a a_ids b_ids
  IFS=. read -r -a a_ids <<< "$a_pre"
  IFS=. read -r -a b_ids <<< "$b_pre"
  local i x y
  local LC_ALL=C
  for ((i = 0; i < ${#a_ids[@]} && i < ${#b_ids[@]}; i++)); do
    x="${a_ids[i]}"
    y="${b_ids[i]}"
    if [[ $x =~ ^[0-9]+$ && $y =~ ^[0-9]+$ ]]; then
      if ((10#$x > 10#$y)); then return 0; fi
      if ((10#$x < 10#$y)); then return 1; fi
    elif [[ $x =~ ^[0-9]+$ ]]; then
      return 1
    elif [[ $y =~ ^[0-9]+$ ]]; then
      return 0
    elif [[ $x != "$y" ]]; then
      if [[ $x > $y ]]; then return 0; else return 1; fi
    fi
  done
  if ((${#a_ids[@]} > ${#b_ids[@]})); then return 0; fi
  return 1
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
    if [[ -z $best ]] || semver_newer "$tag" "$best"; then
      best="$tag"
    fi
  done < <(git -C "$ROOT" tag --list 'v[0-9]*')
  printf '%s' "$best"
}

# previous_version_tag <rev> <version> <skip_same_base> — the newest v* tag
# reachable from <rev> under SemVer precedence, not counting the version being
# published. A stable body sets skip_same_base=1 to skip every candidate of
# the same base and list changes across the whole version; a prerelease skips
# only itself, so each candidate lists changes since the previous one. With no
# version (an unversioned release) any version tag anchors the list. Prints
# nothing when no version tag is reachable.
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
      if [[ -z $best ]] || semver_newer "$tag" "$best"; then
        best="$tag"
      fi
    fi
  done < <(git -C "$ROOT" tag --list 'v[0-9]*')
  printf '%s' "$best"
}

# The release tag names the pin: the version for a version release, or
# `rev-<rev>` for an edge release (GitHub refuses branch/tag names of
# exactly 40 or 64 hex characters). The artifact name and the consumer
# cache key follow the same pin name.
if [[ -n $version ]]; then
  tag="$version"
  artifact="$version"
else
  tag="rev-${rev_full}"
  artifact="$rev_full"
fi

# A stable version takes Latest, so releasing an older version after a newer
# one would move the recommended install backwards. Pure git, so a dry run
# catches it too. Older content reaches consumers as an unversioned release
# (no --version) instead.
if [[ $channel == stable ]]; then
  newer="$(newest_other_stable_tag "$version")"
  if [[ -n $newer ]] && semver_newer "$newer" "$version"; then
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
    if [[ -n $version ]]; then
      echo "[publish-dist] release $tag already exists in $dist_repo — releases are immutable; bump the version" >&2
    else
      echo "[publish-dist] release $tag already exists in $dist_repo — releases are immutable; publish the next rev" >&2
    fi
    exit 1
  fi
  # A tag without a release is a failed publish, not a second release:
  # refuse it explicitly so a rerun never stacks a second asset set under
  # the same pin name. Removing the leftover tag is a manual repair.
  if [[ -n $version ]] && gh api "repos/$dist_repo/git/ref/tags/$version" >/dev/null 2>&1; then
    echo "[publish-dist] tag $version exists in $dist_repo without a release — remove the leftover tag after confirming no release was created, then rerun" >&2
    exit 1
  fi
fi

# Every dist path must exist in the revision: a partial dist would be vendored
# as a broken tree, so a missing path fails with a clear error here.
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
asset="snails-dist-${artifact}.tar.gz"
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
  echo "[publish-dist] could not stamp $version_file — the revision's metadata format changed" >&2
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
# body whose first line is the pin to record. `install.sh` without arguments
# installs Latest, so the install line names the version or rev whenever the
# channel will not hold Latest (a prerelease or an unversioned release).
notes_out="$out/release-notes.md"
if [[ -n $notes_file ]]; then
  cp "$notes_file" "$notes_out"
else
  {
    printf 'Pin: `SNALS_REV="%s"`\n\n' "$consumer_pin"
    if [[ $channel == stable ]]; then
      printf 'Install the latest release:\n\n```sh\ncurl -fsSL https://raw.githubusercontent.com/snails-rb/snails/main/install.sh | bash\n```\n'
    elif [[ -n $version ]]; then
      printf 'Install this prerelease by its version (it does not take Latest):\n\n```sh\ncurl -fsSL https://raw.githubusercontent.com/snails-rb/snails/main/install.sh | bash -s -- --version %s\n```\n' "$version"
    else
      printf 'Install this unversioned release by its rev (it does not take Latest):\n\n```sh\ncurl -fsSL https://raw.githubusercontent.com/snails-rb/snails/main/install.sh | bash -s -- --rev %s\n```\n' "$rev_full"
    fi
    prev="$(previous_version_tag "$rev_full" "$version" "$skip_same_base")"
    printf '\n## Changes\n\n'
    if [[ -n $prev ]]; then
      prev_rev="$(git -C "$ROOT" rev-parse --verify "${prev}^{commit}")"
      printf 'Since `%s` (`%s`):\n\n' "$prev" "${prev_rev:0:12}"
      git -C "$ROOT" log --no-merges --format='- %s' "$prev..$rev_full"
    else
      printf 'No version tag is reachable — run `git fetch --tags` to anchor this list. Until then the list covers the whole history.\n\n'
      git -C "$ROOT" log --no-merges --format='- %s' "$rev_full"
    fi
    printf '\nReleases are immutable: a pin name gets one asset set, never a replaced one. `pins.toml` is the pin'"'"'s spinel declaration; the dist ships only inside the release tarball.\n'
  } > "$notes_out"
fi
echo "[publish-dist] built $notes_out"

if ((dry)); then
  echo "[publish-dist] target repo: $dist_repo"
  echo "[publish-dist] release tag: $tag (dry run — nothing published)"
  echo "[publish-dist] release title: $release_title"
  echo "[publish-dist] channel: $channel (dry run — nothing published)"
  exit 0
fi

# The release creates its tag at the target commit (a version tag for a
# version release, the rev tag for an edge release), so a pin never
# resolves to a tag without its assets.
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
  echo "[publish-dist] install.sh without arguments now installs this release (Latest)"
elif [[ -n $version ]]; then
  echo "[publish-dist] Latest stays on the last stable release — install this version with 'install.sh --version $version'"
else
  echo "[publish-dist] Latest stays on the last stable release — install this rev with 'install.sh --rev $rev_full'"
fi

# The release created the version tag on the remote. Fetch it so the local
# tag record — the change-list anchor and the older-version check — sees
# the release before the next publish.
if [[ -n $version ]]; then
  if ! git -C "$ROOT" fetch origin "refs/tags/$version:refs/tags/$version" >/dev/null 2>&1; then
    echo "[publish-dist] the release is published, but the local tag $version was not fetched — run 'git fetch --tags' before the next publish" >&2
  fi
  if [[ $channel == stable ]]; then
    echo "[publish-dist] next: bash install.sh, then rerun the app gate without SNAILS_DIR (the installed CLI must carry this version)"
  else
    echo "[publish-dist] next: bash install.sh --version $version, then rerun the app gate without SNAILS_DIR"
  fi
else
  echo "[publish-dist] next: bash install.sh --rev $rev_full, then rerun the app gate without SNAILS_DIR"
fi
