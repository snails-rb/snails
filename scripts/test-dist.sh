#!/bin/bash
# Regression test for the dist lifecycle: the publish script's dry-run
# assets (core paths + LICENSE + REV + sha256 sidecar + pins.toml), the
# target repo name, the version-first release record (title, generated
# notes, stable/prerelease/unversioned channel flags), dist-mode `snails new` (the
# REV file is the pin source), the dist-mode fetch path (`snails sync` on a
# pin that is not the dist's own rev downloads, verifies, caches, and reuses
# the published dist), the version-pin resolution through the target repo's
# tag annotation, `verify-pin` in dist mode (publication check), and
# install.sh (download, verify, unpack, symlink).
#
# The distribution base is a local HTTP server serving the same layout
# as the GitHub releases, so no network is touched; the GitHub-specific
# pieces (the latest-release API, tag naming) are exercised by the
# staging e2e instead.
#
# Usage: bash scripts/test-dist.sh
# Exit: 0=all cases pass, 1=failure.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../cli/vendor-dir.sh
source "$ROOT/cli/vendor-dir.sh"
PUB="$ROOT/scripts/publish-dist.sh"
INSTALL="$ROOT/install.sh"
MAIN="$ROOT/scaffold/main.rb"
SEED="$ROOT/scaffold/seed/gen"
# dist-mode `new` runs the path-helper generator, whose parser is the pinned
# spinel (`spinel --dump-ast`). The fake toolchain answers that call with this
# canned dump of the minimal scaffold's route table, so the gate never needs a
# real spinel build. It is a snapshot: regenerate it with
# `spinel --dump-ast scaffold/new/config/routes.rb` when that file or the
# pinned parser rev changes. The generator's reading contract is pinned by its
# own gate (test-gen-route-helpers) against the real parser.
ROUTE_AST="$ROOT/scripts/fixtures/scaffold-new-routes.ast"
[[ -f $ROUTE_AST ]] || { echo "missing route AST fixture: $ROUTE_AST" >&2; exit 1; }

WORK="$(mktemp -d)"
SERVER_PID=""
cleanup() {
  if [[ -n $SERVER_PID ]]; then
    kill "$SERVER_PID" 2>/dev/null || true
  fi
  # KEEP_WORK=1 preserves the workspace for inspection after a failure.
  if [[ ${KEEP_WORK:-} == 1 ]]; then
    echo "KEPT=$WORK"
  else
    rm -rf "$WORK"
  fi
}
trap cleanup EXIT
cd "$WORK"

pass=0
fail=0
chk() {
  if [[ $2 == "$3" ]]; then
    pass=$((pass + 1))
    echo "ok: $1"
  else
    fail=$((fail + 1))
    echo "FAIL: $1 (exit=$2 want $3)"
  fi
}

# The toolchain resolves cache → PATH → source build; seed the cache with
# a fake dist for the revs the fixtures pin so no case compiles spinel.
export XDG_CACHE_HOME="$WORK/cache"
seed_toolchain() {
  local rev="$1" dir b
  dir="$XDG_CACHE_HOME/snails/spinel/$rev/toolchain"
  mkdir -p "$dir"
  for b in spin spinel; do
    cat > "$dir/$b" <<SH
#!/bin/bash
if [[ \${1:-} == "--version" ]]; then echo "$b unreleased (${rev}f)"; exit 0; fi
if [[ \${1:-} == "--dump-ast" ]]; then cat "$ROUTE_AST"; exit 0; fi
echo "test toolchain: unexpected invocation: \$*" >&2
exit 1
SH
    chmod +x "$dir/$b"
  done
}
# shellcheck source=/dev/null
source "$ROOT/pins.toml"
seed_toolchain 1d26ef6
seed_toolchain "$SPINEL_REV"

mk_contract_app() {
  mkdir -p "$1/config" "$1/app" "$1/gen" "$1/$SNAILS_VENDOR_DIR" "$1/$SNAILS_VENDOR_DIR/snails" "$1/$SNAILS_VENDOR_DIR/boot"
  cp "$ROOT/runtime/boot.rb" "$1/$SNAILS_VENDOR_DIR/boot.rb"
  cp "$ROOT/runtime/boot/all.rb" "$1/$SNAILS_VENDOR_DIR/boot/all.rb"
  printf 'require_relative "../%s/database/sqlite"\n' "$SNAILS_VENDOR_DIR" > "$1/config/database.rb"
  cp "$MAIN" "$1/main.rb"
  cp "$ROOT/runtime/snails/health_controller.rb" "$1/$SNAILS_VENDOR_DIR/snails/health_controller.rb"
  cp "$ROOT/scaffold/seed/config/codegen.rb" "$1/config/codegen.rb"
  for name in lib controllers helpers mailers models forms jobs services; do
    cp "$SEED/$name.rb" "$1/gen/$name.rb"
  done
  cat > "$1/config/routes.rb" <<'RB'
# The route table only — controllers load through gen/controllers.rb.
module Snails
  module RouteTable
    def self.table
      [
        ActionDispatch::Router::Route.new("GET", "/up", Snails::HealthController, :show)
      ]
    end
    end
  end
end
RB
}

REV="$(git -C "$ROOT" rev-parse HEAD)"

# 1. dry-run builds the asset pair for the checkout's HEAD.
bash "$PUB" HEAD --dry-run --out out > dry.out 2>&1
chk "dry-run builds the assets" $? 0
grep -q "release tag: rev-$REV" dry.out
chk "the release tag prefixes the rev" $? 0
grep -q "target repo: snails-rb/dist" dry.out
chk "the dry run names the target repo" $? 0
grep -q "built out/pins.toml" dry.out
chk "the dry run builds the pins asset" $? 0
asset="out/snails-dist-$REV.tar.gz"
[[ -f $asset && -f $asset.sha256 && -f out/pins.toml ]]
chk "asset + sha256 sidecar + pins asset exist" $? 0
(cd out && sha256sum -c "snails-dist-$REV.tar.gz.sha256") >/dev/null 2>&1
chk "the sidecar verifies the asset" $? 0

# The target repo is a public interface: a mirror overrides it, and
# a malformed value is refused before anything is built.
bash "$PUB" HEAD --dry-run --out repo-out --dist-repo example/dist > repo-dry.out 2>&1
chk "the dry run takes a target repo override" $? 0
grep -q "target repo: example/dist" repo-dry.out
chk "the override is named in the dry run" $? 0
bash "$PUB" HEAD --dry-run --dist-repo nope > repo-bad.out 2>&1
chk "a malformed target repo is refused" $? 1
grep -q -- '--dist-repo must look like owner/name' repo-bad.out
chk "the malformed target repo is named" $? 0

# 2. the dist layout: core paths + LICENSE + REV, and no repository documents.
mkdir dist
tar -xzf "$asset" -C dist
[[ -x dist/bin/snails && -f dist/pins.toml && -f dist/REV && -f dist/LICENSE ]]
chk "bin/snails + pins.toml + LICENSE + REV extract" $? 0
[[ -d dist/runtime && -d dist/cli && -d dist/scaffold && -f dist/runtime/boot.rb && -f dist/runtime/boot/all.rb && -f dist/scaffold/seed/config/boot.rb ]]
chk "runtime/ cli/ scaffold/ extract (boot entry, all profile, and seed)" $? 0
[[ ! -e dist/README.md && ! -e dist/manual && ! -e dist/.github && ! -e dist/.git ]]
cmp -s dist/LICENSE "$ROOT/LICENSE"
chk "the dist carries the repository LICENSE unchanged" $? 0
chk "no repository documents or .git in the dist" $? 0
[[ "$(cat dist/REV)" == "$REV" ]]
chk "REV names the packaged rev" $? 0
[[ -f dist/runtime/snails/version.rb ]]
chk "the dist carries the version metadata" $? 0
grep -q "^  VERSION = \"$REV\"$" dist/runtime/snails/version.rb
chk "the dist version names the packaged rev" $? 0
grep -q "^  REV = \"$REV\"$" dist/runtime/snails/version.rb
chk "the dist revision names the packaged rev" $? 0

# 3. a rev without the core paths is rejected loud.
mkdir -p fake/scripts
cp "$PUB" fake/scripts/
git -C fake init -q
git -C fake add -A
git -C fake -c user.name=snails -c user.email=snails@test \
  -c commit.gpgsign=false commit -q --no-verify -m "no core paths"
bash fake/scripts/publish-dist.sh HEAD --dry-run --out fake-out > fake.out 2>&1
chk "a rev without the core paths is rejected" $? 1
grep -q 'does not carry runtime' fake.out
chk "the missing path is named" $? 0

# 3b. --version: the release channel alias. The format gate refuses a
#     non-SemVer value before anything is built; a dry run announces the
#     version tag beside the release tag.
bash "$PUB" HEAD --version 9.9.9 --dry-run --out ver-out > ver-format.out 2>&1
chk "--version rejects a non-SemVer value" $? 1
grep -q -- '--version must look like v0.1.0' ver-format.out
chk "the bad version is named with the expected shape" $? 0
bash "$PUB" HEAD --version v9.9.9 --dry-run --out ver-out > ver-dry.out 2>&1
chk "--version dry-run builds the assets" $? 0
grep -q "version tag: v9.9.9" ver-dry.out
chk "the dry run announces the version tag" $? 0
grep -q 'release title: snails v9.9.9' ver-dry.out
chk "the release title is the version" $? 0
grep -q 'channel: stable' ver-dry.out
chk "a stable version is announced as the stable channel" $? 0
grep -q 'Pin: `SNALS_REV="v9.9.9"`' ver-out/release-notes.md
chk "the notes open with the pin to record" $? 0
grep -q 'Install the latest release' ver-out/release-notes.md
chk "a stable release installs without naming a rev" $? 0

bash "$PUB" HEAD --version v9.9.9-rc.1 --dry-run --out ver-rc-out > ver-rc.out 2>&1
chk "--version dry-run builds a prerelease" $? 0
grep -q 'channel: prerelease' ver-rc.out
chk "a prerelease is announced as its own channel" $? 0
grep -q -- "install.sh | bash -s -- --rev $REV" ver-rc-out/release-notes.md
chk "a prerelease installs by rev" $? 0

bash "$PUB" HEAD --dry-run --out unv-out > unv.out 2>&1
chk "a dry run without --version builds the assets" $? 0
grep -q "release title: snails dist ${REV:0:12}" unv.out
chk "an unversioned release is titled by its rev" $? 0
grep -q 'channel: unversioned' unv.out
chk "an unversioned release is announced as its own channel" $? 0
grep -q 'does not take Latest' unv-out/release-notes.md
chk "the unversioned body says it does not take Latest" $? 0
grep -q '## Changes' unv-out/release-notes.md
chk "the generated body carries a change list" $? 0

# 3c. --notes-file: hand-written notes are an input file. A missing or
#     empty one is refused before anything is built, and a valid one
#     replaces the generated body as-is.
bash "$PUB" HEAD --dry-run --out notes-miss-out --notes-file notes-missing.md > notes-miss.out 2>&1
chk "--notes-file rejects a missing file" $? 1
grep -q -- '--notes-file does not exist' notes-miss.out
chk "the missing notes file is named" $? 0
: > notes-empty.md
bash "$PUB" HEAD --dry-run --out notes-empty-out --notes-file notes-empty.md > notes-empty.out 2>&1
chk "--notes-file rejects an empty file" $? 1
grep -q -- '--notes-file is empty' notes-empty.out
chk "the empty notes file is named" $? 0
printf 'Hand-written notes.\n' > notes.md
bash "$PUB" HEAD --dry-run --out notes-out --notes-file notes.md > notes-ok.out 2>&1
chk "--notes-file accepts a hand-written body" $? 0
cmp -s notes.md notes-out/release-notes.md
chk "the hand-written body is used unchanged" $? 0

# 3d. the change list spans the version, not the candidates. A synthetic
#     repo carries v0.1.0, then v0.2.0-rc.1 and v0.2.0-rc.2, then one more
#     commit: a v0.2.0 body starts at v0.1.0 while v0.2.0-rc.3 starts at
#     v0.2.0-rc.2.
mkdir -p tagsrepo
cp -R dist/. tagsrepo/
mkdir -p tagsrepo/scripts
cp "$PUB" tagsrepo/scripts/
git -C tagsrepo init -q
git -C tagsrepo add -A
git -C tagsrepo -c user.name=snails -c user.email=snails@test \
  -c commit.gpgsign=false commit -q --no-verify -m "start"
git -C tagsrepo -c user.name=snails -c user.email=snails@test -c commit.gpgsign=false tag v0.1.0
git -C tagsrepo -c user.name=snails -c user.email=snails@test \
  -c commit.gpgsign=false commit -q --no-verify --allow-empty -m "second"
git -C tagsrepo -c user.name=snails -c user.email=snails@test -c commit.gpgsign=false tag v0.2.0-rc.1
git -C tagsrepo -c user.name=snails -c user.email=snails@test \
  -c commit.gpgsign=false commit -q --no-verify --allow-empty -m "third"
git -C tagsrepo -c user.name=snails -c user.email=snails@test -c commit.gpgsign=false tag v0.2.0-rc.2
bash tagsrepo/scripts/publish-dist.sh HEAD --version v0.2.0 --dry-run --out tags-stable > tags-stable.out 2>&1
chk "a stable body builds in a tagged repo" $? 0
grep -q 'Since `v0.1.0`' tags-stable/release-notes.md
chk "a stable body starts at the previous version" $? 0
bash tagsrepo/scripts/publish-dist.sh HEAD --version v0.2.0-rc.3 --dry-run --out tags-rc > tags-rc.out 2>&1
chk "a prerelease body builds in a tagged repo" $? 0
grep -q 'Since `v0.2.0-rc.2`' tags-rc/release-notes.md
chk "a prerelease body starts at the previous candidate" $? 0

# 3e. a stable release older than a published one is refused: it would take
#     Latest and move the recommended install backwards. Edge releases stay
#     open for older content, so the check is dry-run too. The comparison is
#     against stable tags only — a candidate does not hold Latest.
git -C tagsrepo -c user.name=snails -c user.email=snails@test -c commit.gpgsign=false tag v0.2.0
bash tagsrepo/scripts/publish-dist.sh HEAD --version v0.1.1 --dry-run --out tags-old > tags-old.out 2>&1
chk "a stable release older than a published one is refused" $? 1
grep -q 'is older than the published v0.2.0' tags-old.out
chk "the refusal names the newer version" $? 0
grep -q 'drop --version for an unversioned release' tags-old.out
chk "the refusal names the unversioned alternative" $? 0
bash tagsrepo/scripts/publish-dist.sh HEAD --dry-run --out tags-unv > tags-unv.out 2>&1
chk "an unversioned publish of the same rev is allowed" $? 0
grep -q 'channel: unversioned' tags-unv.out
chk "the allowed publish is announced as unversioned" $? 0

# 3c. version tags are immutable: neither a local tag nor one already
#     on origin may be reused. A synthetic checkout with an origin (a
#     bare clone) exercises both refusals before any gh call.
mkdir -p fakev/scripts
cp "$PUB" fakev/scripts/
git -C fakev init -q
git -C fakev add -A
git -C fakev -c user.name=snails -c user.email=snails@test \
  -c commit.gpgsign=false commit -q --no-verify -m "dist rev"
git init -q --bare fakev-origin
git -C fakev remote add origin "$PWD/fakev-origin"
git -C fakev -c user.name=snails -c user.email=snails@test \
  -c commit.gpgsign=false push -q origin HEAD:main
git -C fakev tag v1.2.3
bash fakev/scripts/publish-dist.sh HEAD --version v1.2.3 --out fakev-out > fakev-local.out 2>&1
chk "an existing local version tag is refused" $? 1
grep -q 'tag v1.2.3 already exists — version tags are immutable' fakev-local.out
chk "the local tag reuse is named" $? 0
# The remote-only case: push the tag, then drop the local ref, so only
# origin still carries v1.2.3.
git -C fakev push -q origin refs/tags/v1.2.3
git -C fakev tag -d v1.2.3 >/dev/null
bash fakev/scripts/publish-dist.sh HEAD --version v1.2.3 --out fakev-out > fakev-remote.out 2>&1
chk "a version tag already on origin is refused" $? 1
grep -q 'tag v1.2.3 already exists on origin' fakev-remote.out
chk "the remote tag reuse is named" $? 0

# 4. dist-mode `new`: an installed dist has no .git — the REV file is the
#    pin source.
bash dist/bin/snails new demo > new.out 2>&1
chk "dist-mode new scaffolds a project" $? 0
grep -q "^SNALS_REV=\"$REV\"$" demo/pins.toml
chk "new records the dist rev as the pin" $? 0
grep -q "^SPINEL_REV=\"$SPINEL_REV\"$" demo/pins.toml
chk "new records the dist's declared spinel rev" $? 0
grep -q '^SNALS_SOURCE="pin"$' demo/pins.toml
chk "new records the dist source as pin" $? 0
[[ -f demo/config/database.rb && ! -e demo/$SNAILS_VENDOR_DIR/database.rb && ! -e demo/boot.rb && -f demo/$SNAILS_VENDOR_DIR/boot.rb && -f demo/$SNAILS_VENDOR_DIR/boot/all.rb && -f demo/config/boot.rb && ! -e demo/app/controllers/snails/health_controller.rb && -f demo/$SNAILS_VENDOR_DIR/snails/health_controller.rb ]]
chk "new stamps the database configuration and vendors the dist core + scaffold (boot and health in core)" $? 0
grep -q "^  VERSION = \"$REV\"$" demo/$SNAILS_VENDOR_DIR/snails/version.rb
chk "new keeps the dist version metadata" $? 0
grep -q 'def self.up_path' demo/gen/route_helpers.rb
chk "new reads the route table through the pinned parser" $? 0

# The dist-mode pin declaration gate: the dist's own rev is trivially
# usable and the SPINEL_REV a fresh project records equals the rev the
# dist's own pins declares (read locally — no network).
bash dist/bin/snails verify-pins demo > vp.out 2>&1
chk "dist-mode verify-pins passes on a fresh project" $? 0
grep -q 'pins ok' vp.out
chk "the dist-mode ok line is printed" $? 0

# 5. serve the release layout locally: a dist for a synthetic rev (its
#    REV rewritten), plus a rev whose checksum sidecar is wrong. FAKE2
#    also serves its pins.toml as a release asset — an installed CLI reads
#    the pair record from the release, not from a source tree.
FAKE="$(printf 'a%.0s' {1..40})"
BAD="$(printf 'b%.0s' {1..40})"
NOPUB="$(printf 'c%.0s' {1..40})"
FAKE2="$(printf 'd%.0s' {1..40})"
cp -R dist fakesrc
printf '%s\n' "$FAKE" > fakesrc/REV
awk -v version="$FAKE" -v rev="$FAKE" '
  /^[[:space:]]*VERSION = / { print "  VERSION = \"" version "\""; next }
  /^[[:space:]]*REV = /     { print "  REV = \"" rev "\""; next }
  { print }
' fakesrc/runtime/snails/version.rb > fakesrc/runtime/snails/version.rb.tmp
mv fakesrc/runtime/snails/version.rb.tmp fakesrc/runtime/snails/version.rb
mkdir -p "serve/rev-$FAKE" "serve/rev-$BAD"
tar -czf "serve/rev-$FAKE/snails-dist-$FAKE.tar.gz" -C fakesrc .
(cd "serve/rev-$FAKE" && sha256sum "snails-dist-$FAKE.tar.gz" > "snails-dist-$FAKE.tar.gz.sha256")
cp "serve/rev-$FAKE/snails-dist-$FAKE.tar.gz" "serve/rev-$BAD/snails-dist-$BAD.tar.gz"
printf '%064d  %s\n' 0 "snails-dist-$BAD.tar.gz" > "serve/rev-$BAD/snails-dist-$BAD.tar.gz.sha256"
cp -R dist fakesrc2
printf '%s\n' "$FAKE2" > fakesrc2/REV
awk -v version="$FAKE2" -v rev="$FAKE2" '
  /^[[:space:]]*VERSION = / { print "  VERSION = \"" version "\""; next }
  /^[[:space:]]*REV = /     { print "  REV = \"" rev "\""; next }
  { print }
' fakesrc2/runtime/snails/version.rb > fakesrc2/runtime/snails/version.rb.tmp
mv fakesrc2/runtime/snails/version.rb.tmp fakesrc2/runtime/snails/version.rb
mkdir -p "serve/rev-$FAKE2"
tar -czf "serve/rev-$FAKE2/snails-dist-$FAKE2.tar.gz" -C fakesrc2 .
(cd "serve/rev-$FAKE2" && sha256sum "snails-dist-$FAKE2.tar.gz" > "snails-dist-$FAKE2.tar.gz.sha256")
printf 'SPINEL_REV="abc1234"\n' > "serve/rev-$FAKE2/pins.toml"

DIST_PORT="${DIST_PORT:-8391}"
(cd serve && exec python3 -m http.server "$DIST_PORT" --bind 127.0.0.1 >/dev/null 2>&1) &
SERVER_PID=$!
for _ in {1..25}; do
  curl -fsS -o /dev/null "http://127.0.0.1:$DIST_PORT/rev-$FAKE/snails-dist-$FAKE.tar.gz.sha256" 2>/dev/null && break
  sleep 0.2
done
curl -fsS -o /dev/null "http://127.0.0.1:$DIST_PORT/rev-$FAKE/snails-dist-$FAKE.tar.gz.sha256"
chk "the local dist server is ready" $? 0

# 6. dist-mode sync fetches a pin that is not the dist's own rev: verified
#    download, cache, and the vendored bytes come from the fetched dist.
cat > fapp-pins.toml <<CONF
SPINEL_REV="1d26ef6"
SNALS_REV="$FAKE"
CONF
mk_contract_app fapp
SNAILS_DIST_BASE_URL="http://127.0.0.1:$DIST_PORT" dist/bin/snails sync fapp --pins fapp-pins.toml > fetch.out 2> fetch.err
chk "dist-mode sync fetches the pinned rev" $? 0
grep -q "fetching dist $FAKE" fetch.err
chk "the fetch is announced" $? 0
grep -q "\[snails\] dist $FAKE cached" fetch.err
chk "the fetched dist is reported" $? 0
if grep -q 'snails/dist' fetch.err; then cache_on_err=1; else cache_on_err=0; fi
chk "the cache path stays out of the default report" "$cache_on_err" 0
grep -q "\[snails\] fapp synced (core ${FAKE:0:7}, spinel 1d26ef6)" fetch.out
chk "the result line names the vendored core" $? 0
[[ -f "$XDG_CACHE_HOME/snails/dist/$FAKE/REV" && "$(cat "$XDG_CACHE_HOME/snails/dist/$FAKE/REV")" == "$FAKE" ]]
chk "the fetched dist lands in the per-rev cache" $? 0
diff -r "$XDG_CACHE_HOME/snails/dist/$FAKE/runtime" fapp/$SNAILS_VENDOR_DIR >/dev/null
chk "the vendored core is the fetched dist's core" $? 0
grep -q "^  VERSION = \"$FAKE\"$" fapp/$SNAILS_VENDOR_DIR/snails/version.rb
chk "sync stamps the fetched version" $? 0
grep -q "^  REV = \"$FAKE\"$" fapp/$SNAILS_VENDOR_DIR/snails/version.rb
chk "sync stamps the fetched revision" $? 0

# --verbose names the cache path the default report omits; clear the
# cache first so the fetch path prints again.
rm -rf "$XDG_CACHE_HOME/snails/dist/$FAKE"
SNAILS_DIST_BASE_URL="http://127.0.0.1:$DIST_PORT" dist/bin/snails sync fapp --pins fapp-pins.toml --verbose > fetchv.out 2> fetchv.err
chk "a verbose dist sync refetches" $? 0
grep -q "dist $FAKE -> $XDG_CACHE_HOME/snails/dist/$FAKE (cache)" fetchv.err
chk "--verbose names the cache path" $? 0

# 7. verify-pin in dist mode checks publication.
SNAILS_DIST_BASE_URL="http://127.0.0.1:$DIST_PORT" dist/bin/snails verify-pin "$FAKE" > vp.out 2>&1
chk "verify-pin: a published rev is usable" $? 0
grep -q "is published" vp.out
chk "verify-pin names the publication" $? 0
SNAILS_DIST_BASE_URL="http://127.0.0.1:$DIST_PORT" dist/bin/snails verify-pin "$NOPUB" >/dev/null 2>&1
chk "verify-pin: an unpublished rev fails" $? 1
dist/bin/snails verify-pin "$REV" > vp-own.out 2>&1
chk "verify-pin: the dist's own rev is usable offline" $? 0
grep -q "own rev" vp-own.out
chk "verify-pin names the own rev" $? 0

# 7b. verify-pins in dist mode reads the PINNED rev's pair record: a rev
#     that is not this dist's and not cached fetches the release's
#     pins.toml asset, and a mismatch names the declared rev.
cat > papp-pins.toml <<CONF
SPINEL_REV="abc1234"
SNALS_REV="$FAKE2"
CONF
SNAILS_DIST_BASE_URL="http://127.0.0.1:$DIST_PORT" \
  dist/bin/snails verify-pins --pins papp-pins.toml > pair.out 2>&1
chk "dist-mode verify-pins fetches the pinned rev's record" $? 0
grep -q 'pins ok (spinel=abc1234' pair.out
chk "the fetched record is the one checked" $? 0

cat > papp-bad.toml <<CONF
SPINEL_REV="deadbee"
SNALS_REV="$FAKE2"
CONF
SNAILS_DIST_BASE_URL="http://127.0.0.1:$DIST_PORT" \
  dist/bin/snails verify-pins --pins papp-bad.toml > pair-bad.out 2>&1
chk "dist-mode verify-pins fails a mismatched pair" $? 1
grep -q '(abc1234)' pair-bad.out
chk "the dist-mode mismatch names the declared rev" $? 0

# The declaration format gate is mode-independent: an abbreviated
# SNALS_REV is refused before dist resolution runs, with the same repair.
cat > papp-abbrev.toml <<CONF
SPINEL_REV="abc1234"
SNALS_REV="${FAKE2:0:7}"
CONF
dist/bin/snails verify-pins --pins papp-abbrev.toml > pair-abbrev.out 2>&1
chk "dist-mode verify-pins fails an abbreviated SNALS_REV" $? 1
grep -q 'is not a full 40-hex rev' pair-abbrev.out
chk "the dist-mode abbreviated pin is named" $? 0
grep -q "run 'git rev-parse ${FAKE2:0:7}'" pair-abbrev.out
chk "the dist-mode repair names the expand command" $? 0

# The release channel in dist mode: a vX.Y.Z pin resolves through the
# target repo's tag. The repo carries no source commits, so the tag
# is annotated on the release-target commit and its message carries
# REV=<source rev>; the CLI reads the tag object.
mkdir -p serve/api/git/ref/tags serve/api/git/tags
TAGOBJ="$(printf 'e%.0s' {1..40})"
printf '{"ref":"refs/tags/v9.9.9","object":{"sha":"%s","type":"tag"}}\n' "$TAGOBJ" \
  > serve/api/git/ref/tags/v9.9.9
printf '{"tag":"v9.9.9","message":"snails v9.9.9 REV=%s","object":{"sha":"%s","type":"commit"}}\n' "$FAKE2" "$FAKE" \
  > "serve/api/git/tags/$TAGOBJ"
cat > papp-version.toml <<CONF
SPINEL_REV="abc1234"
SNALS_REV="v9.9.9"
CONF
SNAILS_GIT_BASE_URL="http://127.0.0.1:$DIST_PORT/api" \
SNAILS_DIST_BASE_URL="http://127.0.0.1:$DIST_PORT" \
  dist/bin/snails verify-pins --pins papp-version.toml > pair-version.out 2>&1
chk "dist-mode verify-pins resolves a vX.Y.Z pin" $? 0
grep -q 'pins ok (spinel=abc1234 snails=v9.9.9)' pair-version.out
chk "the dist ok line shows the declared version" $? 0

# A version tag the API does not know is loud, with the tag repair.
cat > papp-noversion.toml <<CONF
SPINEL_REV="abc1234"
SNALS_REV="v0.0.0"
CONF
SNAILS_GIT_BASE_URL="http://127.0.0.1:$DIST_PORT/api" \
  dist/bin/snails verify-pins --pins papp-noversion.toml > pair-noversion.out 2>&1
chk "dist-mode verify-pins fails an unknown vX.Y.Z" $? 1
grep -q 'names no release tag v0.0.0' pair-noversion.out
chk "the dist-mode unknown version names the tag" $? 0

# 8. loud failures: a checksum mismatch leaves no cache, an abbreviated
#    pin cannot resolve in dist mode.
cat > bapp-pins.toml <<CONF
SPINEL_REV="1d26ef6"
SNALS_REV="$BAD"
CONF
mk_contract_app bapp
SNAILS_DIST_BASE_URL="http://127.0.0.1:$DIST_PORT" dist/bin/snails sync bapp --pins bapp-pins.toml > bad.out 2>&1
chk "a checksum mismatch fails the sync" $? 1
grep -q "checksum mismatch" bad.out
chk "the mismatch is named" $? 0
[[ ! -e "$XDG_CACHE_HOME/snails/dist/$BAD" ]]
chk "no cache entry survives a mismatch" $? 0

cat > short-pins.toml <<CONF
SPINEL_REV="1d26ef6"
SNALS_REV="deadbee"
CONF
mk_contract_app sapp
dist/bin/snails sync sapp --pins short-pins.toml > short.out 2>&1
chk "an abbreviated pin fails in dist mode" $? 1
grep -q "full 40-hex" short.out
chk "the abbreviated pin is named" $? 0

# 9. install.sh: download, verify, unpack, symlink — and the same loud
#    failures as the fetch path.
SNAILS_DIST_BASE_URL="http://127.0.0.1:$DIST_PORT" SNAILS_HOME="$WORK/ihome" SNAILS_BIN_DIR="$WORK/ibin" \
  bash "$INSTALL" --rev "$FAKE" > inst.out 2> inst.err
chk "install.sh installs the dist" $? 0
grep -q "downloading dist $FAKE" inst.err
chk "the download progress is on stderr" $? 0
# install.sh prints this line on success, with the prefix the CLI message
# contract gives it — that script owns the string, this checks it arrived.
grep -q "\[snails\] dist $FAKE -> " inst.out
chk "the install result is on stdout" $? 0
[[ -f "$WORK/ihome/dist/$FAKE/REV" && "$(cat "$WORK/ihome/dist/$FAKE/REV")" == "$FAKE" ]]
chk "the dist lands under SNAILS_HOME" $? 0
[[ "$(readlink "$WORK/ibin/snails")" == "$WORK/ihome/dist/$FAKE/bin/snails" ]]
chk "the snails symlink points at the dist" $? 0
"$WORK/ibin/snails" help >/dev/null 2>&1
chk "the installed CLI runs" $? 0
"$WORK/ibin/snails" verify-scaffold "$WORK/fapp" >/dev/null 2>&1
chk "the symlinked CLI resolves its dist root" $? 0
SNAILS_DIST_BASE_URL="http://127.0.0.1:$DIST_PORT" SNAILS_HOME="$WORK/ihome" SNAILS_BIN_DIR="$WORK/ibin" \
  bash "$INSTALL" --rev "$FAKE" > inst2.out 2>&1
chk "install.sh is idempotent" $? 0
grep -q "already installed" inst2.out
chk "the re-run is announced" $? 0
SNAILS_DIST_BASE_URL="http://127.0.0.1:$DIST_PORT" SNAILS_HOME="$WORK/ihome3" SNAILS_BIN_DIR="$WORK/ibin3" \
  bash "$INSTALL" --rev "$FAKE" >/dev/null 2>&1
chk "install.sh --rev installs a named rev" $? 0
SNAILS_DIST_BASE_URL="http://127.0.0.1:$DIST_PORT" SNAILS_HOME="$WORK/ihome-bad" SNAILS_BIN_DIR="$WORK/ibin-bad" \
  bash "$INSTALL" --rev "$BAD" > inst-bad.out 2>&1
chk "install.sh refuses a checksum mismatch" $? 1
grep -q "checksum mismatch" inst-bad.out
chk "the install mismatch is named" $? 0
[[ ! -e "$WORK/ihome-bad/dist/$BAD" ]]
chk "no install survives a mismatch" $? 0
SNAILS_HOME="$WORK/ihome-short" SNAILS_BIN_DIR="$WORK/ibin-short" \
  bash "$INSTALL" --rev "deadbee" >/dev/null 2>&1
chk "install.sh refuses an abbreviated rev" $? 1

# 10. the cache serves a repeat sync with the server gone.
kill "$SERVER_PID" 2>/dev/null || true
SERVER_PID=""
mk_contract_app fapp2
SNAILS_DIST_BASE_URL="http://127.0.0.1:$DIST_PORT" dist/bin/snails sync fapp2 --pins fapp-pins.toml > cached.out 2>&1
chk "a cached rev syncs without the server" $? 0
grep -q "fetching dist" cached.out
chk "no fetch happens on the cache hit" $? 1

echo "----"
echo "pass=$pass fail=$fail"
if ((fail > 0)); then
  exit 1
fi
exit 0
