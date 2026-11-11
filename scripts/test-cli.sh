#!/bin/bash
# Regression test for the snails CLI (bin/snails) — the single consumer
# entry point that wraps the sync/scaffold/pin engine, including the
# SPINEL_REV toolchain contract (materialize → fresh --check → stale
# detection → repair, and the loud failure for a pins file without the
# toolchain rev).
#
# Usage: bash scripts/test-cli.sh
# Exit: 0=all cases pass, 1=failure.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../cli/vendor-dir.sh
source "$ROOT/cli/vendor-dir.sh"
# shellcheck source=../cli/core-check.sh
source "$ROOT/cli/core-check.sh"
CLI="$ROOT/bin/snails"
BOOT="$ROOT/runtime/boot.rb"
BOOT_ALL="$ROOT/runtime/boot/all.rb"
BOOT_PROFILE_SEED="$ROOT/scaffold/seed/config/boot.rb"
MAIN="$ROOT/scaffold/main.rb"
SEED="$ROOT/scaffold/seed/gen"

WORK="$(mktemp -d)"
# KEEP_WORK=1 preserves the workspace for inspection after a failure.
if [[ ${KEEP_WORK:-} == 1 ]]; then
  trap 'echo "KEPT=$WORK"' EXIT
else
  trap 'rm -rf "$WORK"' EXIT
fi
cd "$WORK"

# No case may compile spinel: seed the cache with a fake toolchain for every
# rev the cases use. The fixture rev (1d26ef6) covers pin presence and
# freshness; the core pin ($SPINEL_REV) is the one `new` stamps, and its
# route parser answers from canned ASTs of the two fixed scaffold route
# tables. The parser's real contract (row grammar, name derivation,
# collisions, --check staleness) is pinned by test-gen-route-helpers.sh
# against the pinned spinel, and test-dist.sh uses the same canned-AST
# approach for its dist-mode `new`.
#
# The fake reports `<rev>f`: long enough for the hex `--version` parsing,
# and a prefix match for the pin either way. Regenerate a fixture when its
# route template or the pinned parser rev changes:
#   spinel --dump-ast scaffold/new/config/routes.rb > scripts/fixtures/scaffold-new-routes.ast
#   spinel --dump-ast scaffold/full/config/routes.rb > scripts/fixtures/scaffold-full-routes.ast
export XDG_CACHE_HOME="$WORK/cache"
ROUTE_AST_MIN="$ROOT/scripts/fixtures/scaffold-new-routes.ast"
ROUTE_AST_FULL="$ROOT/scripts/fixtures/scaffold-full-routes.ast"
for ast in "$ROUTE_AST_MIN" "$ROUTE_AST_FULL"; do
  [[ -f $ast ]] || { echo "missing route AST fixture: $ast" >&2; exit 1; }
done
seed_fake_toolchain() {
  local rev="$1" dir b
  dir="$XDG_CACHE_HOME/snails/spinel/$rev/toolchain"
  mkdir -p "$dir"
  for b in spin spinel; do
    cat > "$dir/$b" <<SH
#!/bin/bash
if [[ \${1:-} == "--version" ]]; then echo "$b unreleased (${rev}f)"; exit 0; fi
if [[ \${1:-} == "--dump-ast" ]]; then
  if cmp -s "\${2:-}" "$ROOT/scaffold/new/config/routes.rb"; then
    cat "$ROUTE_AST_MIN"
  elif cmp -s "\${2:-}" "$ROOT/scaffold/full/config/routes.rb"; then
    cat "$ROUTE_AST_FULL"
  else
    echo "test toolchain: no canned AST for \${2:-}" >&2
    exit 1
  fi
  exit 0
fi
echo "test toolchain: unexpected invocation: \$*" >&2
exit 1
SH
    chmod +x "$dir/$b"
  done
}
# shellcheck source=/dev/null
source "$ROOT/pins.toml"
seed_fake_toolchain 1d26ef6         # the fixture rev (pin presence/freshness)
seed_fake_toolchain "$SPINEL_REV"   # the core pin `new` stamps (route AST only)

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

# compare_core <expected> <actual> — byte-compare the vendored core
# except the generated version metadata file. A pin's core carries the
# default constants; sync stamps the resolved values, so the caller asserts
# that file separately.
compare_core() {
  local expected="$1" actual="$2" left right rc
  left="$(mktemp -d)"
  right="$(mktemp -d)"
  cp -R "$expected" "$left/runtime"
  cp -R "$actual" "$right/runtime"
  rm -f "$left/runtime/snails/version.rb" "$right/runtime/snails/version.rb"
  diff -r "$left/runtime" "$right/runtime" >/dev/null
  rc=$?
  rm -rf "$left" "$right"
  return $rc
}

mk_contract_app() {
  mkdir -p "$1/config" "$1/app" "$1/gen" "$1/$SNAILS_VENDOR_DIR" "$1/$SNAILS_VENDOR_DIR/snails" "$1/$SNAILS_VENDOR_DIR/boot"
  cp "$MAIN" "$1/main.rb"
  cp "$BOOT" "$1/$SNAILS_VENDOR_DIR/boot.rb"
  cp "$BOOT_ALL" "$1/$SNAILS_VENDOR_DIR/boot/all.rb"
  printf 'require_relative "../%s/database/sqlite"\n' "$SNAILS_VENDOR_DIR" > "$1/config/database.rb"
  cp "$ROOT/runtime/snails/health_controller.rb" "$1/$SNAILS_VENDOR_DIR/snails/health_controller.rb"
  cp "$ROOT/scaffold/seed/config/application.rb" "$1/config/application.rb"
  cp "$BOOT_PROFILE_SEED" "$1/config/boot.rb"
  cp "$ROOT/scaffold/new/config/environment.rb" "$1/config/environment.rb"
  cp "$ROOT/scaffold/seed/config/codegen.rb" "$1/config/codegen.rb"
  for name in lib controllers helpers mailers models forms jobs services route_helpers; do
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
RB
}

# 1. help, version, unknown command, and project-command hints
bash "$CLI" --help > overview.out 2>&1
chk "overview help" $? 0
[[ $(wc -l < overview.out) -le 30 ]]
chk "overview is 30 lines or fewer" $? 0
grep -q '^Common$' overview.out && ! grep -q 'harness test' overview.out
chk "overview groups public commands and hides internal ones" $? 0
grep -q 'bin/dev' overview.out && grep -q 'bin/test' overview.out
chk "overview points at the project wrappers" $? 0
bash "$CLI" help sync > sync-help.out 2>&1
chk "help <command>" $? 0
grep -q '^Usage: snails sync' sync-help.out
chk "help <command> is command-specific" $? 0
bash "$CLI" --version > version.out 2>&1
chk "version" $? 0
[[ $(wc -l < version.out) -eq 1 ]]
chk "version is one line" $? 0
bash "$CLI" harness test --help > harness-help.out 2>&1
chk "harness test --help is read-only" $? 0
grep -q '^Usage: snails harness test' harness-help.out
chk "harness test help is command-specific" $? 0
bash "$CLI" migrate apply --help > migrate-help.out 2>&1
chk "migrate subcommand help" $? 0
grep -q '^Usage: snails migrate apply' migrate-help.out
chk "migrate subcommand help is command-specific" $? 0
bash "$CLI" migrate load --help > migrate-load-help.out 2>&1
chk "migrate load help" $? 0
grep -q '^Usage: snails migrate load' migrate-load-help.out
chk "migrate load help is command-specific" $? 0
bash "$CLI" generate > generate-list.out 2>&1
chk "generate without a generator lists generators" $? 0
grep -q 'job_queue' generate-list.out
chk "the generator list names job_queue" $? 0
bash "$CLI" bogus > bogus.out 2>&1
chk "unknown command" $? 2
[[ $(wc -l < bogus.out) -le 4 ]]
chk "unknown command stays short" $? 0
! grep -q '^usage: snails' bogus.out
chk "unknown command does not dump the overview" $? 0
bash "$CLI" test > project-test.out 2>&1
chk "project test hint" $? 2
grep -q 'bin/test' project-test.out
chk "project test hint names bin/test" $? 0
bash "$CLI" dev > project-dev.out 2>&1
chk "project dev hint" $? 2
grep -q 'bin/dev' project-dev.out
chk "project dev hint names bin/dev" $? 0

# 2. sync: core replaced, contract verified, and no app boot is created
mkdir -p app/$SNAILS_VENDOR_DIR
echo old > app/$SNAILS_VENDOR_DIR/old.rb
mk_contract_app app
bash "$CLI" sync app >/dev/null 2>&1
chk "sync app tree" $? 0
[[ ! -f app/$SNAILS_VENDOR_DIR/old.rb ]]
chk "core replaced by sync" $? 0
[[ ! -e app/boot.rb && -f app/$SNAILS_VENDOR_DIR/boot.rb ]]
chk "sync vendors the core boot and creates no app boot" $? 0

# 2a. A tree that still carries the retired app boot is refused before the
#     core is touched, with the migration line.
mk_contract_app retired
echo '# retired app boot' > retired/boot.rb
echo old > retired/$SNAILS_VENDOR_DIR/old.rb
bash "$CLI" sync retired > retired.out 2>&1
chk "sync refuses a retired app boot" $? 1
grep -q 'boot.rb is retired' retired.out
chk "the refusal names the retired boot" $? 0
[[ -f retired/$SNAILS_VENDOR_DIR/old.rb ]]
chk "the refusal writes nothing" $? 0

# 2a2. doctor: the expanded checks name the missing pin, environment, and
#      database target without hiding the failure.
bash "$CLI" doctor app > doctor.out 2>&1
chk "doctor fails when pins are missing" $? 1
grep -q 'pins.toml not found' doctor.out
chk "doctor names the missing pins file" $? 0
grep -q 'SNAILS_ENV: development' doctor.out
chk "doctor reports the app environment" $? 0
grep -q 'database target:' doctor.out
chk "doctor reports the database target" $? 0
SNAILS_ENV=production bash "$CLI" doctor app > doctor-prod.out 2>&1
chk "doctor fails production without a key" $? 1
grep -q 'SECRET_KEY_BASE is not set' doctor-prod.out
chk "doctor names the missing production secret" $? 0

# 2b. app-root resolution: every app-root command accepts its omission and
# resolves the same way — nearest database configuration at or above $PWD. A
# move off $PWD is announced; a $PWD outside every app refuses with the fix.
# A repository root that holds its app in the standard src/ layout resolves
# into src/ — the same app an explicit argument names.
(cd app && bash "$CLI" sync --check) >/dev/null 2>resolve-quiet.err
chk "sync --check from the app root resolves silently" $? 0
chk "no announcement at the app root" "$(grep -c 'auto-resolved' resolve-quiet.err)" 0
(cd app/gen && bash "$CLI" sync --check) >/dev/null 2>resolve-sub.err
chk "sync --check from a subdirectory resolves" $? 0
grep -q "\[snails\] app root $WORK/app (auto-resolved)" resolve-sub.err
chk "the walk announces the resolved app root" $? 0
(cd app && bash "$CLI" verify-scaffold) >/dev/null 2>&1
chk "verify-scaffold from the app root resolves" $? 0
(cd app && bash "$CLI" gen-require-all --check) >/dev/null 2>&1
chk "gen-require-all resolves from the app root" $? 0
mkdir -p bare/config
printf 'require_relative "../%s/database/sqlite"\n' "$SNAILS_VENDOR_DIR" > bare/config/database.rb
(cd bare && bash "$CLI" harness test) >/dev/null 2>harness-resolve.err
chk "harness resolves before checking for harness/" $? 1
grep -q "no harness/ under $WORK/bare" harness-resolve.err
chk "harness resolution reaches the app root" $? 0
(cd "$WORK" && bash "$CLI" verify-scaffold) >/dev/null 2>outside.err
chk "outside any app root refuses" $? 2
grep -q 'pass <app_root>' outside.err
chk "the refusal names the fix" $? 0

# The pins file lives at the app root, so a repository root that holds its
# app in src/ names that app: the omitted resolution follows the standard
# layout into src/ instead of refusing.
mkdir -p proj/.git
cp -R app proj/src
printf 'APP_NAME="proj-fixture"\n' > proj/src/pins.toml
(cd proj && bash "$CLI" verify-scaffold) >/dev/null 2>proj.err
chk "the repository root resolves into src/" $? 0
grep -q "app root $WORK/proj/src (auto-resolved)" proj.err
chk "the src/ resolution is announced" $? 0
(cd proj && bash "$CLI" sync --check --skip-toolchain) >/dev/null 2>proj-sync.err
chk "sync resolves the src/ app from the repository root" $? 0
(cd proj && bash "$CLI" pins path) > proj-path.out 2>/dev/null
chk "pins path resolves the src/ app from the repository root" $? 0
grep -q "$WORK/proj/src/pins.toml" proj-path.out
chk "pins path prints the src/ pins file" $? 0

# A subdirectory outside the app is still not a resolution: the fixed src/
# child belongs to the repository root, not to every descendant.
mkdir -p proj/deploy
(cd proj/deploy && bash "$CLI" verify-scaffold) >/dev/null 2>proj-deploy.err
chk "a subdirectory outside the src/ app refuses" $? 2
grep -q 'pass <app_root>' proj-deploy.err
chk "the subdirectory refusal names the fix" $? 0

# A repository root without the standard src/ app still refuses.
mkdir -p nosrc/.git nosrc/src
(cd nosrc && bash "$CLI" verify-scaffold) >/dev/null 2>nosrc.err
chk "a repository root without an app refuses" $? 2
grep -q 'pass <app_root>' nosrc.err
chk "the repository-root refusal names the fix" $? 0

# 2c. An explicit argument is the other half of the rule: the caller named
#     a place, so a repository root that holds its app in src/ names that
#     app. The omitted and explicit halves agree for the standard layout;
#     the boundary cases above keep them honest.
bash "$CLI" pins-path proj > proj-pins.out 2>&1
chk "pins-path follows an explicit repository root into src/" $? 0
grep -q "$WORK/proj/src/pins.toml" proj-pins.out
chk "pins-path prints the src/ pins file" $? 0
bash "$CLI" verify-scaffold proj >/dev/null 2>&1
chk "verify-scaffold accepts an explicit repository root" $? 0
bash "$CLI" gen-require-all proj --check >/dev/null 2>&1
chk "gen-require-all accepts an explicit repository root" $? 0
bash "$CLI" harness test proj > proj-harness.out 2>&1
chk "harness stops at the src/ app it resolved to" $? 1
grep -q "$WORK/proj/src/pins.toml" proj-harness.out
chk "harness names the src/ pins file, not the repository root" $? 0

# 3. sync --check: clean, then stale core
bash "$CLI" sync app --check >/dev/null 2>&1
chk "check clean" $? 0
echo '# drift' >> app/$SNAILS_VENDOR_DIR/database/sqlite.rb
bash "$CLI" sync app --check >/dev/null 2>&1
chk "check detects stale core" $? 1

# The stale report exists to say "sync": the default output is that one
# action line (stderr), and the drift list is diagnostics behind
# --verbose.
bash "$CLI" sync app --check > stale.out 2> stale.err
chk "stale check still exits 1" $? 1
chk "the stale frame keeps stdout clean" "$(wc -c < stale.out | tr -d ' ')" 0
chk "the stale frame is one stderr line" "$(wc -l < stale.err | tr -d ' ')" 1
grep -q "$SNAILS_VENDOR_DIR is stale — run: snails sync app" stale.err
chk "the stale frame names the repair" $? 0

# --verbose swaps the category summary and the per-file list in. The three
# shapes get one entry each: a nested changed file, a nested pin-only
# file, and a top-level tree-only file.
echo 'local extra' > app/$SNAILS_VENDOR_DIR/local_extra.rb
rm app/$SNAILS_VENDOR_DIR/tep/app.rb
bash "$CLI" sync app --check --verbose > verbose.out 2> verbose.err
chk "verbose stale check exits 1" $? 1
chk "verbose keeps the action line first" "$(head -n1 verbose.err | grep -c "$SNAILS_VENDOR_DIR is stale")" 1
grep -q 'changed 1 · pin-only 1 · tree-only 1' verbose.err
chk "verbose summarizes the drift categories" $? 0
grep -q "changed   $SNAILS_VENDOR_DIR/database/sqlite.rb" verbose.err
chk "changed entries use app-relative paths" $? 0
grep -q "pin-only  $SNAILS_VENDOR_DIR/tep/app.rb" verbose.err
chk "pin-only entries use app-relative paths" $? 0
grep -q "tree-only $SNAILS_VENDOR_DIR/local_extra.rb" verbose.err
chk "tree-only entries use app-relative paths" $? 0
grep '^\[snails\]   ' verbose.err | grep -qE '(^|[[:space:]])/'
chk "no staging path leaks into the drift report" $? 1

# --verbose is the single detail flag: with --check it lists the drift,
# and a plain sync accepts it too. stdout carries the result line either
# way; the retired boot-rebuild detail must not come back.
bash "$CLI" sync app --verbose > verbose-sync.out 2> verbose-sync.err
chk "sync --verbose without --check is accepted" $? 0
chk "the verbose sync keeps stdout to the result line" "$(wc -l < verbose-sync.out | tr -d ' ')" 1
grep -q '\[snails\] app synced (core checkout)' verbose-sync.out
chk "the result line names the vendored core" $? 0
if grep -q 'rebuilt from' verbose-sync.err; then boot_source=1; else boot_source=0; fi
chk "the retired boot rebuild detail is gone" "$boot_source" 0

bash "$CLI" sync app --check > sync.out 2>/dev/null
chk "repaired check exits 0" $? 0
chk "the in-sync report is one stdout line" "$(wc -l < sync.out | tr -d ' ')" 1

# The image engines stage the CLI into build/image-context/ (gitignored,
# re-included in the Docker context), outside snails-core/ — the vendored
# core stays an exact copy of the pinned tree, so no drift exclusion is
# needed.
# shellcheck source=../cli/image-context.sh
source "$ROOT/cli/image-context.sh"
stage_image_context "$WORK/app"
[[ -x "$WORK/app/build/image-context/snails/bin/snails" && ! -e "$WORK/app/$SNAILS_VENDOR_DIR/deploy" ]]
chk "the image context stages outside the vendored core" $? 0
bash "$CLI" sync app --check >/dev/null 2>&1
chk "a staged image context is not core drift" $? 0
grep -q '^!build/image-context' "$ROOT/scaffold/new/.dockerignore"
chk "the Docker context re-includes the staged CLI" $? 0

# The legacy per-app patch flag is gone: --overlay must be refused as an
# unknown flag (loud, not silently ignored) and the usage must stop
# advertising it.
bash "$CLI" sync app --overlay some/dir >/dev/null 2>&1
chk "sync refuses --overlay" $? 2
bash "$CLI" help 2>&1 | grep -q -- '--overlay'
chk "usage does not advertise --overlay" $? 1

# 4. sync --pins reads SNALS_REV and verifies before vendoring
cat > pins.toml <<'CONF'
SPINEL_REV="1d26ef6"
SNALS_REV="deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
CONF
bash "$CLI" sync app --pins pins.toml >/dev/null 2>&1
chk "sync --pins fails on unknown rev" $? 1

# The same declaration format gate in sync: an abbreviated pin is refused
# with the repair line before git/dist resolution runs.
cat > pins-abbrev.toml <<'CONF'
SPINEL_REV="1d26ef6"
SNALS_REV="deadbee"
CONF
bash "$CLI" sync app --pins pins-abbrev.toml > sync-abbrev.out 2>&1
chk "sync --pins fails on an abbreviated SNALS_REV" $? 1
grep -q 'is not a full 40-hex rev' sync-abbrev.out
chk "sync names the abbreviated pin" $? 0
grep -q "run 'git rev-parse deadbee'" sync-abbrev.out
chk "sync's repair names the expand command" $? 0

# 5. verify-pin wiring
bash "$CLI" verify-pin deadbeef >/dev/null 2>&1
chk "verify-pin unknown rev" $? 1
bash "$CLI" verify-pin pins.toml >/dev/null 2>&1
chk "verify-pin reads pins.toml" $? 1
bash "$CLI" verify-pin >/dev/null 2>&1
chk "verify-pin defaults to the cwd pins file" $? 1
mkdir no-pins-cwd
(cd no-pins-cwd && bash "$CLI" verify-pin) >/dev/null 2>&1
chk "verify-pin missing arg without a cwd pins file" $? 2

# 6. sync --pins vendors the PIN when the checkout moved past it.
#    Synthetic snails checkout: commit A is the pin, the OLDEST layout
#    (engine dir script/) whose pins.toml carries the retired
#    SPINEL_VALIDATED_REVS list — the pre-pair-record shape, so
#    the compatibility reader is exercised by every fixture pinned to A.
#    Commit B renames the engine dir to scripts/ (the previous
#    generation) and adds core content the pin
#    does not have; commit C renames the engine dir to cli/ (current)
#    and writes the SPINEL_REV record; commit D drops the declaration
#    (the verify-pins gate is held to each shape). A sync pinned to A or
#    B must restore that rev's engine and vendor it under the new CLI.
PINSNAILS="$WORK/pin-snails"
mkdir -p "$PINSNAILS"
for p in bin cli scaffold runtime pins.toml; do
  cp -R "$ROOT/$p" "$PINSNAILS/"
done
gitsnap() {
  # --no-verify: the global comment hook flags upstream issue refs in the
  # copied core (snails' documented provenance exception).
  git -C "$PINSNAILS" -c user.name=snails -c user.email=snails@test \
    -c commit.gpgsign=false "$@"
}
mv "$PINSNAILS/cli" "$PINSNAILS/script"
# A real pre-rename rev's engines reference their own directory name; the
# snapshot gets that shape so the extracted engine is self-consistent.
sed -i 's|/cli/|/script/|g' "$PINSNAILS/script/sync-runtime.sh"
printf 'SPINEL_VALIDATED_REVS="1d26ef6"\n' > "$PINSNAILS/pins.toml"
gitsnap init -q
gitsnap add -A
gitsnap commit -q --no-verify -m "pin rev"
PIN_REV="$(git -C "$PINSNAILS" rev-parse HEAD)"
git -C "$PINSNAILS" mv script scripts
sed -i 's|/script/|/scripts/|g' "$PINSNAILS/scripts/sync-runtime.sh"
echo "# core moved past the pin" > "$PINSNAILS/runtime/pin_probe.rb"
gitsnap add -A
gitsnap commit -q --no-verify -m "renamed to scripts"
MID_REV="$(git -C "$PINSNAILS" rev-parse HEAD)"
git -C "$PINSNAILS" mv scripts cli
sed -i 's|/scripts/|/cli/|g' "$PINSNAILS/cli/sync-runtime.sh"
gitsnap add -A
gitsnap commit -q --no-verify -m "renamed to cli"
printf 'SPINEL_REV="abc1234"\n' > "$PINSNAILS/pins.toml"
gitsnap add -A
gitsnap commit -q --no-verify -m "pair record"
SCALAR_REV="$(git -C "$PINSNAILS" rev-parse HEAD)"
printf '# spinel declaration pending\n' > "$PINSNAILS/pins.toml"
gitsnap add -A
gitsnap commit -q --no-verify -m "declaration dropped"
NODECL_REV="$(git -C "$PINSNAILS" rev-parse HEAD)"

# The retired pins.conf name is a hard boundary, not a fallback: a rev
# carrying only it is not a usable pin.
git -C "$PINSNAILS" mv pins.toml pins.conf
gitsnap add -A
gitsnap commit -q --no-verify -m "pins.conf only"
CONF_ONLY_REV="$(git -C "$PINSNAILS" rev-parse HEAD)"
bash "$PINSNAILS/bin/snails" verify-pin "$CONF_ONLY_REV" > conf-only.out 2>&1
chk "verify-pin refuses a rev that carries only pins.conf" $? 1
grep -q 'does not carry' conf-only.out
chk "the refusal names the missing pins file" $? 0
git -C "$PINSNAILS" reset --hard -q HEAD~1

cat > pin-ahead.toml <<CONF
SPINEL_REV="1d26ef6"
SNALS_REV="$PIN_REV"
CONF

bash "$PINSNAILS/bin/snails" verify-pin "$PIN_REV" > ahead-notice.txt 2>&1
chk "verify-pin passes with the checkout ahead" $? 0
grep -q "notice:" ahead-notice.txt && grep -q "ahead of the pin" ahead-notice.txt
chk "verify-pin prints the ahead notice" $? 0
# The commit list is the notice's detail layer: default stays one line.
if grep -q "renamed to scripts" ahead-notice.txt; then ahead_listed=1; else ahead_listed=0; fi
chk "the default notice omits the commit list" "$ahead_listed" 0
bash "$PINSNAILS/bin/snails" verify-pin "$PIN_REV" --verbose > ahead-verbose.txt 2>&1
chk "verify-pin --verbose passes" $? 0
grep -q "renamed to scripts" ahead-verbose.txt
chk "--verbose adds the core-touching commit" $? 0

mk_contract_app pinapp
bash "$PINSNAILS/bin/snails" sync pinapp --pins pin-ahead.toml > pin-sync.txt 2>&1
chk "sync --pins succeeds with the checkout ahead" $? 0
[[ ! -f pinapp/$SNAILS_VENDOR_DIR/pin_probe.rb ]]
chk "vendored core comes from the pin, not the checkout" $? 0
grep -q '\[snails\] done:' pin-sync.txt
chk "the pre-rename pin's engine ran the sync" $? 0
mkdir pinexp
git -C "$PINSNAILS" archive "$PIN_REV" -- runtime | tar -x -C pinexp
# The adapter is the app's config/database.rb (never a vendored core file), so the
# vendored core must byte-match the pin's core exactly.
compare_core pinexp/runtime pinapp/$SNAILS_VENDOR_DIR
chk "vendored core byte-matches the pin's core" $? 0
grep -q "^  VERSION = \"$PIN_REV\"$" pinapp/$SNAILS_VENDOR_DIR/snails/version.rb
chk "sync stamps the pinned version" $? 0
grep -q "^  REV = \"$PIN_REV\"$" pinapp/$SNAILS_VENDOR_DIR/snails/version.rb
chk "sync stamps the pinned revision" $? 0
bash "$PINSNAILS/bin/snails" sync pinapp --pins pin-ahead.toml --check >/dev/null 2>&1
chk "sync --check --pins agrees with the pin" $? 0

# A pin recorded before this rename carries scripts/ — the common upgrade
# case — and must restore its own engine the same way.
cat > pin-mid.toml <<CONF
SPINEL_REV="1d26ef6"
SNALS_REV="$MID_REV"
CONF
mk_contract_app midapp
bash "$PINSNAILS/bin/snails" sync midapp --pins pin-mid.toml > mid-sync.txt 2>&1
chk "sync --pins restores a scripts/-generation pin" $? 0
grep -q '\[snails\] done:' mid-sync.txt
chk "the scripts/-generation engine ran the sync" $? 0

# 7. verify-scaffold delegates
bash "$CLI" verify-scaffold app >/dev/null 2>&1
chk "verify-scaffold good" $? 0
mk_contract_app bad
sed -i 's|"/up"|"/nope"|' bad/config/routes.rb
bash "$CLI" verify-scaffold bad >/dev/null 2>&1
chk "verify-scaffold bad" $? 1

# 8. new: scaffold a project skeleton and vendor the core. The
#    onboarding block is the result (stdout); the nested sync's progress
#    goes to stderr and its own result line is not echoed.
bash "$CLI" new newapp > new.out 2> new.err
chk "new scaffolds project" $? 0
grep -q '\[snails\] created newapp (GET /up)' new.out
chk "the onboarding result stays on stdout" $? 0
if grep -q 'synced (core' new.out; then nested_sync=1; else nested_sync=0; fi
chk "the nested sync result is not echoed" "$nested_sync" 0
grep -q "\[snails\] core -> newapp/$SNAILS_VENDOR_DIR" new.err
chk "the nested sync progress stays on stderr" $? 0
[[ -f newapp/main.rb && ! -e newapp/boot.rb && -f newapp/$SNAILS_VENDOR_DIR/boot.rb && -f newapp/$SNAILS_VENDOR_DIR/boot/all.rb && -f newapp/config/boot.rb && -f newapp/pins.toml && -f newapp/bin/newapp.rb && -f newapp/bin/test && -f newapp/bin/dev && ! -e newapp/cli/gen-require-all.sh && -f newapp/.gitignore && -f newapp/.env.sample && -f newapp/harness/test.env && ! -e newapp/harness/run && ! -e newapp/harness/dev && ! -e newapp/harness/spin-test.rb && ! -e newapp/harness/spin-test.sh && ! -e newapp/harness/toolchain.sh ]]
chk "new writes expected files (no app boot, no runner copies)" $? 0
grep -q '^# SNAILS_ENV=' newapp/.env.sample && grep -q '^# SECRET_KEY_BASE=' newapp/.env.sample
chk "the environment sample documents the framework variables" $? 0
grep -q '^/.env$' newapp/.gitignore
chk "new ignores the local .env file" $? 0
grep -Fq "require_relative \"$SNAILS_VENDOR_DIR/boot\"" newapp/main.rb
chk "the entry requires the vendored core boot" $? 0
grep -q 'Snails::Main.start' newapp/main.rb
chk "the entry starts Snails::Main" $? 0
grep -Fq "require_relative \"../$SNAILS_VENDOR_DIR/boot\"" newapp/harness/boot.rb
chk "the harness target reuses the core boot" $? 0
grep -q '^SNAILS_ENV=test$' newapp/harness/test.env
chk "the seeded test.env puts the gate server in test mode" $? 0
cmp -s "$MAIN" newapp/main.rb
chk "new stamps the canonical main.rb entry" $? 0
[[ -f newapp/config/environment.rb ]]
chk "new stamps the app environment file" $? 0
grep -Fq 'Snails.time_zone = "UTC"' newapp/config/environment.rb && grep -Fq 'Snails.app.secret_key_base' newapp/config/environment.rb && ! grep -q 'LocalSecret' newapp/config/environment.rb
chk "the environment stamp carries the default boot settings and the standard key reader" $? 0
grep -Fq 'ActionMailer::Base.delivery_method = ActionMailer::DeliveryLog if Snails.env.test?' newapp/config/environment.rb
chk "the environment stamp registers the test-mode mail capture" $? 0
grep -q 'require_relative "../config/boot"' newapp/$SNAILS_VENDOR_DIR/boot.rb
chk "the core boot entry requires the app profile" $? 0
grep -Fq "require_relative \"../$SNAILS_VENDOR_DIR/boot/all\"" newapp/config/boot.rb
chk "the new app selects the all profile" $? 0
grep -q 'require_relative "../../config/environment"' newapp/$SNAILS_VENDOR_DIR/boot/all.rb
chk "the all profile requires the app environment last" $? 0
grep -q 'get("/up"' newapp/config/routes.rb
chk "new wires GET /up" $? 0
[[ -f newapp/config/database.rb && ! -e newapp/$SNAILS_VENDOR_DIR/database.rb && -f newapp/$SNAILS_VENDOR_DIR/database/sqlite.rb && ! -e newapp/app/controllers/snails/health_controller.rb && -f newapp/$SNAILS_VENDOR_DIR/snails/health_controller.rb ]]
chk "new stamps the app database configuration and vendors an adapter-free core (health in core)" $? 0
grep -q '"newapp"' newapp/config/application.rb
chk "new substitutes the app name" $? 0
! grep -q '^DB=' newapp/pins.toml
chk "pins carries no retired DB= key" $? 0
grep -q '^APP_NAME="newapp"$' newapp/pins.toml
chk "new writes the app name" $? 0
grep -q "^SPINEL_REV=\"$SPINEL_REV\"$" newapp/pins.toml
chk "new stamps the core's declared spinel rev" $? 0
grep -q '^SNALS_SOURCE="checkout"$' newapp/pins.toml
chk "new declares the checkout source" $? 0
grep -Fq "require_relative \"../$SNAILS_VENDOR_DIR/database/sqlite\"" newapp/config/database.rb
chk "new stamps the sqlite database configuration" $? 0
# The stamped wrappers resolve the CLI and hand off — the pin check and the
# gen/* refresh live in the engine now, so no wrapper carries a generator
# call. The engines own the refresh: cli/generators.sh is sourced by every
# build path.
! grep -q 'gen-require-all\|gen-route-helpers\|gen-model-columns' newapp/bin/test &&
  ! grep -q 'gen-require-all\|gen-route-helpers\|gen-model-columns' newapp/bin/dev &&
  grep -q 'SNAILS_DIR' newapp/bin/test
chk "the stamped wrappers carry no generator copy" $? 0
grep -q 'harness test "$ROOT"' newapp/bin/test && grep -q 'harness dev "$ROOT"' newapp/bin/dev
chk "the stamped wrappers hand off to the harness engine" $? 0
grep -q 'generators.sh' "$ROOT/cli/harness-test.sh" && grep -q 'run_generators' "$ROOT/cli/harness-test.sh" &&
  grep -q 'generators.sh' "$ROOT/cli/harness-dev.sh" && grep -q 'run_generators' "$ROOT/cli/harness-dev.sh" &&
  grep -q 'run_generators' "$ROOT/cli/build-image.sh" && grep -q 'run_generators' "$ROOT/cli/build-binary.sh"
chk "every build path refreshes gen/* through the shared generator step" $? 0
grep -q 'run_generators' "$ROOT/cli/generators.sh"
chk "the generator sequence has one source" $? 0
grep -q 'require_relative "../../config/codegen"' newapp/$SNAILS_VENDOR_DIR/boot/all.rb && grep -q 'require_relative "../gen/route_helpers"' newapp/config/codegen.rb && grep -q 'def self.up_path' newapp/gen/route_helpers.rb
chk "new generates the path helpers the core boot requires" $? 0
grep -q 'require_relative "../gen/lib"' newapp/config/codegen.rb && [[ -f newapp/gen/lib.rb ]]
chk "new seeds the shared lib require-all group" $? 0
# The stamped files come from scaffold/new templates: the wrappers are
# copied byte-for-byte, the compile root is renamed and substituted, and
# no placeholder may survive.
[[ -x newapp/bin/test && -x newapp/bin/dev && -x newapp/bin/build-image && -x newapp/bin/build-binary && -x newapp/bin/compose ]]
chk "the stamped wrappers are executable" $? 0
cmp -s "$ROOT/scaffold/new/bin/test" newapp/bin/test && cmp -s "$ROOT/scaffold/new/bin/dev" newapp/bin/dev && cmp -s "$ROOT/scaffold/new/bin/build-image" newapp/bin/build-image && cmp -s "$ROOT/scaffold/new/bin/build-binary" newapp/bin/build-binary && cmp -s "$ROOT/scaffold/new/bin/compose" newapp/bin/compose
chk "the wrappers byte-match the scaffold templates" $? 0
grep -Fq 'build-image "$ROOT"' newapp/bin/build-image && grep -Fq 'build-binary "$ROOT"' newapp/bin/build-binary && grep -Fq 'compose "$ROOT" --' newapp/bin/compose && ! grep -q 'gen-require-all' newapp/bin/build-binary
chk "the build wrappers call the CLI engines (no copy)" $? 0
# No build engine refuses a source: a checkout source builds like any other.
# The engines still validate the value through the shared reader, so a typo
# fails before anything compiles.
for eng in build-image build-binary compose; do
  if grep -q 'pins_require_pin' "$ROOT/cli/$eng.sh"; then eng_refuses=1; else eng_refuses=0; fi
  chk "$eng does not refuse a declared source" "$eng_refuses" 0
  if grep -qF 'pins_source "$pins_file"' "$ROOT/cli/$eng.sh"; then eng_validates=1; else eng_validates=0; fi
  chk "$eng validates the declared source" "$eng_validates" 1
done
# The build engines parse pins through the shared reader (cli/pins.sh):
# no engine sources the file, so a value that is a string to the TOML
# parser can never run as shell, and the discovery walk matches the one
# verify-pins validates with.
for eng in build-image build-binary compose; do
  if grep -q 'source "$APP_ROOT/pins.toml"' "$ROOT/cli/$eng.sh"; then eng_sourced=1; else eng_sourced=0; fi
  chk "$eng does not source the pins file" "$eng_sourced" 0
  grep -q 'pins_discover "$APP_ROOT"' "$ROOT/cli/$eng.sh"
  chk "$eng discovers pins with the shared reader" $? 0
done
# And the read really goes through that reader: the pins file above the
# app root is the file verify-pins checked and the file the engine reads.
# Sourcing a fixed <app_root>/pins.toml would die on the missing file
# instead of reaching the value guard.
mkdir -p enginewalk/app
cat > enginewalk/pins.toml <<CONF
SPINEL_REV="1d26ef6"
SNALS_REV="$PIN_REV"
CONF
bash "$PINSNAILS/cli/build-image.sh" "$WORK/enginewalk/app" >enginewalk.out 2>&1
grep -q 'is missing APP_NAME' enginewalk.out
chk "build-image reads the discovered pins file" $? 0
if grep -q 'No such file' enginewalk.out; then eng_missingfile=1; else eng_missingfile=0; fi
chk "build-image never sources a fixed pins path" "$eng_missingfile" 0
# The sqlite compose recipe bind-mounts ./storage, so the engine creates
# that directory as the calling user before docker runs — docker would
# make it root-owned and the container could not write.
grep -Fq 'mkdir -p "$(dirname "$COMPOSE_FILE")/storage"' "$ROOT/cli/compose.sh" && grep -q 'adapter == "sqlite"' "$ROOT/cli/compose.sh"
chk "the compose engine creates the sqlite storage dir as the calling user" $? 0
[[ ! -e newapp/bin/__APP_NAME__.rb ]] && grep -q 'build/bin/newapp' newapp/bin/newapp.rb
chk "the template compile root is renamed and substituted" $? 0
[[ -d newapp/storage ]]
chk "new creates the sqlite storage directory" $? 0
[[ -f newapp/Dockerfile && -f newapp/.dockerignore && -f newapp/bin/build-image && -f newapp/bin/build-binary && -f newapp/bin/compose && -f newapp/compose.yml && -f newapp/deploy/Caddyfile && ! -e newapp/container-entrypoint ]]
chk "new stamps the image build and deploy assets (no entrypoint shim)" $? 0
[[ -x newapp/bin/build-image && -x newapp/bin/build-binary && -x newapp/bin/compose ]]
chk "the image and deploy wrappers are executable" $? 0
grep -q 'FROM ghcr.io/snails-rb/spinel:${SPINEL_REV}' newapp/Dockerfile && grep -Fq '      sqlite3 \' newapp/Dockerfile && grep -q 'VOLUME /snails/storage' newapp/Dockerfile && grep -q 'DATABASE_PATH=/snails/storage/production.sqlite3' newapp/Dockerfile && grep -Fq 'COPY --from=app-build /app/build/image-context/snails' newapp/Dockerfile && grep -Fq 'RUN ln -s /usr/local/lib/snails/bin/snails /usr/local/bin/snails' newapp/Dockerfile && grep -Fq 'CMD ["/usr/local/bin/app"]' newapp/Dockerfile && ! grep -q 'ENTRYPOINT' newapp/Dockerfile
chk "the sqlite image template stamps the client package, storage, and the runner on PATH" $? 0
grep -q 'stage_image_context "$APP_ROOT"' "$ROOT/cli/build-image.sh" && grep -q 'stage_image_context "$APP_ROOT"' "$ROOT/cli/compose.sh" && grep -q 'build/image-context/snails' "$ROOT/cli/image-context.sh"
chk "the image engines stage the CLI build context" $? 0
grep -Fq 'SNAILS_MIGRATE_REPAIR="bin/compose run --rm app snails migrate apply"' newapp/Dockerfile && grep -q 'SNAILS_MIGRATE_REPAIR' "$ROOT/cli/migrate.sh" && ! grep -q 'SNAILS_MIGRATE_IN_CONTAINER' "$ROOT/cli/migrate.sh"
chk "the image supplies the host repair command to the runner" $? 0
grep -q 'DATABASE_PATH: /snails/storage/production.sqlite3' newapp/compose.yml && grep -q './storage:/snails/storage' newapp/compose.yml && grep -q 'PUID' newapp/compose.yml && grep -q 'driver: local' newapp/compose.yml && grep -q 'max-size: "20m"' newapp/compose.yml && grep -q 'max-file: "5"' newapp/compose.yml && grep -q 'compress: "true"' newapp/compose.yml && ! grep -q 'postgres' newapp/compose.yml && ! grep -q 'app_storage' newapp/compose.yml
chk "the sqlite compose file binds storage, maps the uid, and bounds the log" $? 0
[[ ! -e newapp/compose.sqlite.yml && ! -e newapp/compose.pg.yml ]]
chk "new leaves one compose file" $? 0
! grep -Eq '__[A-Z_]+__' newapp/config/application.rb newapp/config/database.rb newapp/bin/newapp.rb newapp/pins.toml newapp/Dockerfile newapp/compose.yml newpg/compose.yml
chk "no placeholder survives stamping" $? 0
rm -r newapp/.spinel
bash "$CLI" sync newapp --skip-toolchain >/dev/null 2>&1
chk "sync --skip-toolchain vendors the core" $? 0
[[ ! -e newapp/.spinel/toolchain ]]
chk "sync --skip-toolchain leaves the toolchain unmaterialized" $? 0
bash "$CLI" sync newapp --check --skip-toolchain >/dev/null 2>&1
chk "sync --check --skip-toolchain" $? 0
# A value carrying a replacement metacharacter must land literally: `&`
# used to be expanded as the match by the substitution.
bash "$CLI" new 'meta&app' >/dev/null 2>&1
chk "new with a metacharacter app name" $? 0
grep -Fq '"meta&app"' 'meta&app/config/application.rb' && grep -q '^APP_NAME="meta&app"$' 'meta&app/pins.toml'
chk "the metacharacter name is stamped literally" $? 0
bash "$CLI" new newpg --database=postgresql >/dev/null 2>&1
chk "new --database=postgresql" $? 0
grep -Fq "require_relative \"../$SNAILS_VENDOR_DIR/database/postgresql\"" newpg/config/database.rb
chk "new stamps the pg database configuration" $? 0
[[ ! -e newpg/storage ]]
chk "new leaves no sqlite storage directory on the pg adapter" $? 0
grep -q 'postgresql-client' newpg/Dockerfile && grep -q 'PG_URL is provided' newpg/Dockerfile && ! grep -q 'VOLUME /snails/storage' newpg/Dockerfile
chk "the pg image template stamps the pg client package" $? 0
grep -q 'postgres:18-alpine' newpg/compose.yml && grep -q 'PG_URL' newpg/compose.yml && ! grep -q 'DATABASE_PATH' newpg/compose.yml
chk "the pg compose file carries the database service" $? 0
! grep -q 'POSTGRES_USER' newpg/compose.yml && grep -q 'postgres://postgres:' newpg/compose.yml
chk "the pg compose file uses the image default user" $? 0
grep -q 'POSTGRES_DB: newpg_production' newpg/compose.yml && grep -q '5432/newpg_production' newpg/compose.yml && grep -q 'pg_isready -U postgres -d newpg_production' newpg/compose.yml
chk "the pg database follows the app_environment naming" $? 0
grep -q 'driver: local' newpg/compose.yml && grep -q 'max-size: "20m"' newpg/compose.yml && grep -q 'max-file: "5"' newpg/compose.yml && grep -q 'compress: "true"' newpg/compose.yml
chk "the pg compose file bounds the app log" $? 0
! grep -q '127.0.0.1:5432' newpg/compose.yml
chk "the pg compose file publishes no host port (the runner is in the container)" $? 0
bash "$CLI" new newbad --database=oracle >/dev/null 2>&1
chk "new rejects an unknown database" $? 2
[[ ! -e newbad ]]
chk "rejected database leaves no tree" $? 0
bash "$CLI" new newapp >/dev/null 2>&1
chk "new refuses non-empty target" $? 1
bash "$CLI" new >/dev/null 2>&1
chk "new missing arg" $? 2
bash "$CLI" new newfull --scaffold >/dev/null 2>&1
chk "new --scaffold scaffolds project" $? 0
[[ -d newfull/storage ]]
chk "new --scaffold creates the sqlite storage directory" $? 0
[[ -f newfull/app/models/post.rb && -f newfull/app/models/comment.rb && -f newfull/app/forms/post_form.rb && -f newfull/app/controllers/api/posts_controller.rb && -f newfull/app/controllers/api/posts_controller.rbs && -f newfull/app/controllers/api/comments_controller.rb && -f newfull/app/controllers/api/comments_controller.rbs && -f newfull/harness/test/posts_test.rb && -f newfull/harness/test/posts_test.rb.expected && -f newfull/harness/test/comments_test.rb && -f newfull/harness/test/comments_test.rb.expected && -f newfull/harness/test/post_form_test.rb && -f newfull/harness/test/post_form_test.rb.expected && -f newfull/harness/test/adapter_test.rb && -f newfull/harness/test/adapter_test.rb.expected ]]
chk "new --scaffold writes the full template" $? 0
cmp -s "$MAIN" newfull/main.rb
chk "new --scaffold keeps the canonical main.rb entry" $? 0
baseline_sqlite="$(printf '%s\n' newfull/db/migrate/[0-9]*_baseline.sql)"
[[ $baseline_sqlite == newfull/db/migrate/[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]_baseline.sql ]] &&
  grep -q 'INTEGER PRIMARY KEY' "$baseline_sqlite" &&
  [[ ! -e newfull/db/migrate/0001_baseline.sqlite.sql && ! -e newfull/db/migrate/0001_baseline.pg.sql && ! -e newfull/db/schema.sql ]]
chk "new --scaffold stamps the sqlite baseline as a UTC migration and writes no schema dump" $? 0
grep -q '"/posts"' newfull/config/routes.rb
chk "new --scaffold wires the posts routes" $? 0
grep -q '"/posts/:post_id/comments"' newfull/config/routes.rb
chk "new --scaffold wires the nested comments routes" $? 0
grep -q 'require_relative "../app/models/post"' newfull/gen/models.rb && grep -q 'require_relative "../app/models/comment"' newfull/gen/models.rb
chk "new --scaffold requires the models in gen/models.rb" $? 0
grep -q 'api/posts_controller' newfull/gen/controllers.rb && grep -q 'api/comments_controller' newfull/gen/controllers.rb
chk "new --scaffold requires the api controllers in gen/controllers.rb" $? 0
grep -q 'require_relative "../app/forms/post_form"' newfull/gen/forms.rb
chk "new --scaffold requires the form in gen/forms.rb" $? 0
grep -q 'Api::PostsController' newfull/config/routes.rb && grep -q 'Api::CommentsController' newfull/config/routes.rb
chk "new --scaffold wires the controller classes in the route table" $? 0
bash "$CLI" new newfullpg --scaffold --database=postgresql >/dev/null 2>&1
chk "new --scaffold accepts the postgresql adapter" $? 0
baseline_pg="$(printf '%s\n' newfullpg/db/migrate/[0-9]*_baseline.sql)"
grep -q 'BIGSERIAL PRIMARY KEY' "$baseline_pg" && grep -q 'database/postgresql' newfullpg/config/database.rb
chk "new --scaffold pg selects the pg DDL and database configuration" $? 0
[[ -f $baseline_pg && ! -e newfullpg/db/migrate/0001_baseline.sqlite.sql && ! -e newfullpg/db/migrate/0001_baseline.pg.sql && ! -e newfullpg/db/schema.sql ]]
chk "new --scaffold pg stamps the baseline as a UTC migration and writes no schema dump" $? 0
bash "$CLI" verify-scaffold newfull >/dev/null 2>&1
chk "new --scaffold passes verify-scaffold" $? 0

# 8b. A linked worktree is a checkout too: git stores its `.git` there as a
# file pointing at the real git dir, so a directory-only test misses it and
# the fresh app would ship VERSION/REV as "unknown".
git -C "$ROOT" worktree add --detach "$WORK/wt" HEAD >/dev/null 2>&1
chk "linked worktree setup" $? 0
bash "$WORK/wt/bin/snails" new wtapp >/dev/null 2>&1
chk "new runs from a linked worktree" $? 0
wt_rev="$(git -C "$WORK/wt" rev-parse HEAD)"
grep -q "^  REV = \"$wt_rev\"$" wtapp/$SNAILS_VENDOR_DIR/snails/version.rb
chk "the worktree checkout stamps its HEAD revision" $? 0
grep -q "^  VERSION = \"$wt_rev" wtapp/$SNAILS_VENDOR_DIR/snails/version.rb
chk "the worktree checkout stamps the core version" $? 0

# 8c. The harness core check follows the pins declaration. A checkout-created
#     app names the checkout working tree; a pin app names the pin. The check
#     never guesses: a pin app that happens to match the checkout still runs
#     the pin check, and a checkout source needs a checkout CLI.
sed -i 's/^SNALS_SOURCE=.*/SNALS_SOURCE="pin"/' wtapp/pins.toml
core_check "$WORK/wt/bin/snails" wtapp >/dev/null 2>&1
chk "core check accepts the declared pin source" $? 0
chk "the pin source is named" "$CORE_SOURCE" "pin"

sed -i '/^SNALS_SOURCE=/d' wtapp/pins.toml
core_check "$WORK/wt/bin/snails" wtapp >/dev/null 2>&1
chk "an app without a source key defaults to pin" $? 0
chk "the default source is named" "$CORE_SOURCE" "pin"

sed -i 's/^SNALS_SOURCE=.*/SNALS_SOURCE="pin"/' wtapp/pins.toml
"$CLI" sync wtapp --from-checkout > wtflag.out 2>&1
chk "sync --from-checkout requires the checkout declaration" $? 1
grep -q 'SNALS_SOURCE="pin"' wtflag.out
chk "the refusal names the declaration" $? 0

printf '\n# local edit probe\n' >> "$WORK/wt/runtime/snails/version.rb"
bash "$WORK/wt/bin/snails" new wtdirty >/dev/null 2>&1
chk "new runs from a dirty worktree" $? 0
sed -i '/^SNALS_REV=/a SNALS_SOURCE="checkout"' wtdirty/pins.toml
grep -q '^SNALS_SOURCE="checkout"$' wtdirty/pins.toml
chk "the dirty app declares the checkout source" $? 0
check_log="$WORK/core-check.log"
core_check "$WORK/wt/bin/snails" wtdirty >"$check_log" 2>&1; check_rc=$?
chk "core check accepts the declared checkout source" "$check_rc" 0
chk "the checkout source is named" "$CORE_SOURCE" "checkout"
if grep -q 'stale' "$check_log"; then check_stale=1; else check_stale=0; fi
chk "the checkout check never runs the pin check" "$check_stale" 0

printf 'stray\n' > "wtdirty/$SNAILS_VENDOR_DIR/stale-probe.txt"
core_check "$WORK/wt/bin/snails" wtdirty >"$check_log" 2>&1; check_rc=$?
chk "core check stops on a stray vendored file" "$check_rc" 1
chk "the rejected check clears the source" "$CORE_SOURCE" ""
grep -q 'stale' "$check_log"
chk "the rejected check names the repair" $? 0

# An installed dist has no working tree: a checkout-sourced app is refused.
mkdir -p fakedist/bin
cp "$ROOT/bin/snails" fakedist/bin/snails
touch fakedist/REV
core_check fakedist/bin/snails wtdirty >"$check_log" 2>&1; check_rc=$?
chk "a checkout source needs a checkout CLI" "$check_rc" 1
grep -q 'SNALS_SOURCE="checkout"' "$check_log"
chk "the refusal names the source" $? 0
chk "an installed dist is not a working-tree source" "$(core_checkout_root fakedist/bin/snails)" ""

cp wtdirty/pins.toml "$WORK/wtdirty-pins.bak"
sed -i 's/^SNALS_SOURCE=.*/SNALS_SOURCE="bogus"/' wtdirty/pins.toml
core_check "$WORK/wt/bin/snails" wtdirty >"$check_log" 2>&1; check_rc=$?
chk "an invalid source is refused" "$check_rc" 1
grep -q 'SNALS_SOURCE must be "pin" or "checkout"' "$check_log"
chk "the invalid source names the accepted values" $? 0
cp "$WORK/wtdirty-pins.bak" wtdirty/pins.toml

git -C "$ROOT" worktree remove --force "$WORK/wt"
git -C "$ROOT" worktree prune

# 9. pins discovery — the walk-up, .git-bounded contract. The pins file
#    sits at the app root, so the walk's job is a start inside the app
#    (a subdirectory of it), never a search above the app.
# (a) the pins file at the app root is the pin
mkdir -p d1/src
echo 'SNALS_REV=aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111' > d1/src/pins.toml
bash "$CLI" sync d1/src > d1.out 2>&1
chk "discovery: sync fails on the discovered pin's unknown rev" $? 1
grep -q 'unknown SNALS_REV: aaaa1111' d1.out
chk "discovery: the pins file at the app root is used" $? 0

# (b) a start deeper inside the app climbs to that same file
mkdir -p d1/src/nested
bash "$CLI" sync d1/src/nested > d1nested.out 2>&1
grep -q 'unknown SNALS_REV: aaaa1111' d1nested.out
chk "discovery: a subdirectory start finds the app root's pins file" $? 0

# (c) a discovered file without SNALS_REV is a declaration only: the
#     sync falls back to this checkout and says so. SPINEL_REV is still
#     part of the contract (a pins file that exists must declare the
#     toolchain rev), and a legacy DB= only seeds a missing database configuration —
#     it never overrides the app's config/database.rb.
mkdir -p d3/src/$SNAILS_VENDOR_DIR
mk_contract_app d3/src
cat > d3/src/pins.toml <<'CONF'
SPINEL_REV=1d26ef6
DB=pg
CONF
bash "$CLI" sync d3/src > d3.out 2>&1
chk "discovery: no-SNALS_REV file falls back to the checkout" $? 0
grep -q 'has no SNALS_REV' d3.out
chk "discovery: the fallback is announced" $? 0
[[ ! -e d3/src/$SNAILS_VENDOR_DIR/database.rb ]] && grep -q database/sqlite d3/src/config/database.rb
chk "a legacy DB= does not override the existing database configuration" $? 0

# (c2) a tree without the database configuration gets it seeded once — the pins DB=
#      names the adapter, and the file is app-owned from then on.
rm d3/src/config/database.rb
bash "$CLI" sync d3/src > d3seed.out 2>&1
chk "a missing database configuration is seeded by sync" $? 0
grep -Fq "require_relative \"../$SNAILS_VENDOR_DIR/database/postgresql\"" d3/src/config/database.rb
chk "the pins DB= names the seeded adapter" $? 0

# (d) a checkout source is a declaration: the pins file names it, and sync
#     does not verify the pin rev in that mode (the legacy DB= is seed-only
#     there too — the adapter is config/database.rb)
mkdir -p d4/src/$SNAILS_VENDOR_DIR
mk_contract_app d4/src
cat > d4/src/pins.toml <<'CONF'
SPINEL_REV=1d26ef6
SNALS_REV=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
SNALS_SOURCE="checkout"
DB=pg
CONF
bash "$CLI" sync d4/src --from-checkout > d4.out 2>&1
chk "sync --from-checkout does not verify the pin rev" $? 0
[[ ! -e d4/src/$SNAILS_VENDOR_DIR/database.rb ]] && grep -q database/sqlite d4/src/config/database.rb
chk "sync --from-checkout leaves the adapter to the app entry" $? 0

# (e) an explicit --pins beats discovery (and --pins takes any path)
mkdir -p d5/src
echo 'SNALS_REV=eeee4444eeee4444eeee4444eeee4444eeee4444' > d5/src/pins.toml
echo 'SNALS_REV=dddd5555dddd5555dddd5555dddd5555dddd5555' > d5/explicit.conf
bash "$CLI" sync d5/src --pins d5/explicit.conf > d5.out 2>&1
chk "explicit --pins wins over the discovered file" $? 1
grep -q 'unknown SNALS_REV: dddd5555' d5.out
chk "the explicit --pins rev is the one used" $? 0

# (f) the walk stops at the .git boundary: a pins file above the repo
#     root is never discovered, one at the app root next to .git is
mkdir -p d6/repo/src/$SNAILS_VENDOR_DIR
touch d6/repo/.git
echo 'SNALS_REV=ffff6666ffff6666ffff6666ffff6666ffff6666' > d6/pins.toml
mk_contract_app d6/repo/src
bash "$CLI" sync d6/repo/src > d6.out 2>&1
chk "discovery: pins above the .git boundary are ignored" $? 0
echo 'SNALS_REV=9999999999999999999999999999999999999999' > d6/repo/src/pins.toml
bash "$CLI" sync d6/repo/src > d6b.out 2>&1
chk "discovery: pins at the app root are used" $? 1
grep -q 'unknown SNALS_REV: 99999999' d6b.out
chk "the app-root pin is the one used" $? 0

# (g) the retired pins.conf name is not a pins file any more — a directory
#     holding only it discovers nothing (bounded by its own .git).
mkdir -p d7/src
touch d7/.git
echo 'SNALS_REV=1111111111111111111111111111111111111111' > d7/src/pins.conf
bash "$CLI" pins-path d7/src > d7.out 2>&1
chk "discovery: the retired pins.conf name is refused" $? 1
grep -q 'no pins file at or above' d7.out
chk "the refusal is the one-line pins-path message" $? 0

# 10. spinel toolchain — SPINEL_REV materializes the project copy next to
#     the pins file, --check sees a stale copy, sync repairs it, a pins
#     file without the rev fails loud, and a pin older than the toolchain
#     contract keeps its old (no-materialization) behavior. Own pins dir:
#     the toolchain copy lives next to the pins file, and an earlier case
#     already seeded $WORK/.spinel.
mkdir -p tcdir
cat > tcdir/pins.toml <<CONF
SPINEL_REV="1d26ef6"
SNALS_REV="$PIN_REV"
CONF
mk_contract_app tcapp
bash "$PINSNAILS/bin/snails" sync tcapp --pins tcdir/pins.toml > tc.out 2> tc.err
chk "sync materializes the pinned toolchain" $? 0
grep -q "\[snails\] tcapp synced (core ${PIN_REV:0:7}, spinel 1d26ef6)" tc.out
chk "the result line names the vendored revs" $? 0
[[ $(wc -l < tc.out) -eq 1 ]]
chk "progress stays off stdout" $? 0
grep -q 'spinel 1d26ef6 -> .*toolchain (cache)' tc.err
chk "the materialization source is reported on stderr" $? 0
[[ -x tcdir/.spinel/toolchain/spin && -x tcdir/.spinel/toolchain/spinel ]]
chk "toolchain lands next to the pins file" $? 0
tcdir/.spinel/toolchain/spin --version 2>/dev/null | grep -q '1d26ef6'
chk "the materialized toolchain reports the pin" $? 0
bash "$PINSNAILS/bin/snails" sync tcapp --pins tcdir/pins.toml --check >/dev/null 2>&1
chk "check clean with a fresh toolchain" $? 0

cat > tcdir/.spinel/toolchain/spin <<'SH'
#!/bin/bash
echo "spin unreleased (0000000a)"
SH
chmod +x tcdir/.spinel/toolchain/spin
bash "$PINSNAILS/bin/snails" sync tcapp --pins tcdir/pins.toml --check > tc-stale.out 2>&1
chk "check detects a stale toolchain" $? 1
grep -q 'missing or stale' tc-stale.out
chk "the stale report names the repair" $? 0
grep -q "snails sync .*tcapp" tc-stale.out
chk "the repair names the app root" $? 0
bash "$PINSNAILS/bin/snails" sync tcapp --pins tcdir/pins.toml > tc-fix.out 2>&1
chk "sync repairs the stale toolchain" $? 0
bash "$PINSNAILS/bin/snails" sync tcapp --pins tcdir/pins.toml --check >/dev/null 2>&1
chk "check clean after repair" $? 0

# The gate resolution recipe must beat a failing PATH spin: the cached
# toolchain wins and the decoy is never invoked. The recipe mirrors what
# scripts/test-runtime.sh does (ensure + absolute PATH pin + assert).
DECOY="$WORK/decoy"
mkdir -p "$DECOY" decoy-pins
printf 'SPINEL_REV="1d26ef6"\n' > decoy-pins/pins.toml
for b in spin spinel; do
  cat > "$DECOY/$b" <<SH
#!/bin/bash
touch "$WORK/decoy-invoked"
exit 1
SH
  chmod +x "$DECOY/$b"
done
cat > resolve-recipe.sh <<'SH'
source "$1/cli/toolchain.sh"
spinel_toolchain_ensure "$2/pins.toml" >/dev/null 2>&1 || exit 1
export PATH="$(spinel_toolchain_dir "$2/pins.toml"):$PATH"
[[ $(command -v spin) == "$(spinel_toolchain_dir "$2/pins.toml")/spin" ]]
SH
recipe_rc=0
PATH="$DECOY:$PATH" bash resolve-recipe.sh "$ROOT" "$WORK/decoy-pins" || recipe_rc=$?
chk "the gate recipe resolves the cached toolchain ahead of a decoy PATH" "$recipe_rc" 0
[[ ! -e "$WORK/decoy-invoked" ]]
chk "the decoy PATH spin was never invoked" $? 0
grep -q 'spinel_toolchain_ensure' "$ROOT/scripts/test-runtime.sh"
chk "the core gate carries the pinned-toolchain resolver" $? 0

# A PATH entry that is a launcher, not a toolchain, must not be executed.
# The snails shim calls `snails exec`, which re-enters this resolver; the
# layout check rejects it before any `--version` run, so a fresh cache falls
# through instead of recursing. The decoy records an invocation.
LAUNCHER="$WORK/launcher"
mkdir -p "$LAUNCHER"
for b in spin spinel; do
  cat > "$LAUNCHER/$b" <<SH
#!/bin/bash
touch "$WORK/launcher-invoked"
exit 1
SH
  chmod +x "$LAUNCHER/$b"
done
cat > path-source.sh <<'SH'
source "$1/cli/toolchain.sh"
spinel_toolchain_path_source "$2"
SH
launcher_out="$(PATH="$LAUNCHER:$PATH" bash path-source.sh "$ROOT" 1d26ef6)"
chk "a launcher on PATH is not accepted as a toolchain" "$launcher_out" ""
[[ ! -e "$WORK/launcher-invoked" ]]
chk "the launcher was never executed" $? 0
# A complete pinned layout on PATH is accepted. The binaries are the fake;
# the resolver's contract is the layout plus the reported rev, not a compile.
COMPLETE="$WORK/complete-toolchain"
mkdir -p "$COMPLETE/builtins" "$COMPLETE/lib" "$COMPLETE/packages"
cp "$XDG_CACHE_HOME/snails/spinel/$SPINEL_REV/toolchain/spin" "$COMPLETE/spin"
cp "$XDG_CACHE_HOME/snails/spinel/$SPINEL_REV/toolchain/spinel" "$COMPLETE/spinel"
chmod +x "$COMPLETE/spin" "$COMPLETE/spinel"
real_expected="$(cd "$COMPLETE" && pwd -P)"
real_out="$(PATH="$COMPLETE:$PATH" bash path-source.sh "$ROOT" "$SPINEL_REV")"
chk "a complete toolchain on PATH is still accepted" "$real_out" "$real_expected"

# The core checkout itself is refused as a sync target (self-vendor would
# delete the core's runtime/).
bash "$CLI" sync "$ROOT" > guard.out 2>&1
chk "sync refuses the core checkout itself" $? 1
grep -q 'core checkout itself' guard.out
chk "the refusal names the core checkout" $? 0
mkdir -p fake-core/scaffold
cp "$ROOT/scaffold/main.rb" fake-core/scaffold/main.rb
bash "$CLI" sync fake-core > guard-marker.out 2>&1
chk "sync refuses a core checkout by its scaffold marker" $? 1
grep -q 'scaffold/' guard-marker.out
chk "the marker refusal names scaffold/" $? 0

# `snails exec` runs a command from the pins file's pinned toolchain and
# refuses loudly when the pins file or the command is missing.
mkdir -p execdir
cat > execdir/pins.toml <<CONF
SPINEL_REV="1d26ef6"
CONF
out=$(cd execdir && bash "$CLI" exec spin --version 2>/dev/null)
chk "exec runs a pinned toolchain command" $? 0
grep -q '1d26ef6' <<<"$out"
chk "exec resolves the pinned toolchain rev" $? 0
out=$(cd execdir && bash "$CLI" exec spinel --version 2>/dev/null)
chk "exec resolves the second toolchain binary" $? 0
out=$(cd execdir && bash "$CLI" exec no-such-command 2>&1); exec_rc=$?
chk "exec refuses a command outside the toolchain" "$exec_rc" 1
grep -q 'not in the pinned toolchain' <<<"$out"
chk "the exec miss names the toolchain" $? 0
NODIR="$(mktemp -d)"
out=$(cd "$NODIR" && SNAILS_SPINEL_HOME="$WORK/no-standalone" bash "$CLI" exec spin 2>&1); exec_rc=$?
chk "exec refuses without a pins file or standalone" "$exec_rc" 1
grep -q 'no pins file' <<<"$out"
chk "the refusal names the missing pin" $? 0
grep -q 'no standalone spinel' <<<"$out"
chk "the refusal names the standalone fallback" $? 0
out=$(cd "$NODIR" && SNAILS_SPINEL_HOME= bash "$CLI" exec spin 2>&1); exec_rc=$?
chk "an empty SNAILS_SPINEL_HOME disables the fallback" "$exec_rc" 1
rm -rf "$NODIR"

# Outside pinned trees the standalone install takes over, announced.
STANDALONE="$WORK/standalone"
mkdir -p "$STANDALONE"
printf '#!/bin/bash\necho "standalone spin $*"\n' > "$STANDALONE/spin"
chmod +x "$STANDALONE/spin"
NODIR="$(mktemp -d)"
out=$(cd "$NODIR" && SNAILS_SPINEL_HOME="$STANDALONE" bash "$CLI" exec spin --version 2>&1); exec_rc=$?
rm -rf "$NODIR"
chk "exec falls back to the standalone spinel outside pins" "$exec_rc" 0
grep -q 'standalone spin --version' <<<"$out"
chk "the fallback runs the standalone binary" $? 0
grep -q 'using the standalone spinel' <<<"$out"
chk "the fallback is announced" $? 0
out=$(cd execdir && SNAILS_SPINEL_HOME="$STANDALONE" bash "$CLI" exec spin --version 2>/dev/null)
chk "the pinned toolchain wins over the fallback" $? 0
grep -q '1d26ef6' <<<"$out"
chk "the pinned resolution is unchanged by the fallback" $? 0

# `snails install-shim` writes the spin/spinel shims idempotently,
# replaces the classic personal-install symlink, and refuses foreign
# files.
SHIMBIN="$WORK/shimbin"
out=$(bash "$CLI" install-shim --bin-dir "$SHIMBIN" 2>/dev/null)
chk "install-shim writes the shims" $? 0
grep -q 'shims ready' <<<"$out"
chk "the result line names the shim dir" $? 0
[[ -x "$SHIMBIN/spin" && -x "$SHIMBIN/spinel" ]]
chk "the shim files are executable" $? 0
cmp -s "$SHIMBIN/spin" "$ROOT/scaffold/shim/tool"
chk "the shim is the external file, copied verbatim" $? 0
grep -qF 'exec snails exec "$tool" "$@"' "$SHIMBIN/spin"
chk "the shim delegates to snails exec with its own name" $? 0
out=$(bash "$CLI" install-shim --bin-dir "$SHIMBIN" 2>&1)
chk "install-shim is idempotent" $? 0
grep -q 'already current' <<<"$out"
chk "a re-run reports the shims as current" $? 0
SLINKBIN="$WORK/slinkbin"; mkdir -p "$SLINKBIN" "$WORK/fakehome"
printf '#!/bin/bash\necho fake standalone\n' > "$WORK/fakehome/spin"
chmod +x "$WORK/fakehome/spin"
ln -s "$WORK/fakehome/spin" "$SLINKBIN/spin"
out=$(SNAILS_SPINEL_HOME="$WORK/fakehome" bash "$CLI" install-shim --bin-dir "$SLINKBIN" 2>&1)
chk "install-shim replaces the personal-install symlink" $? 0
[[ ! -L "$SLINKBIN/spin" ]] && cmp -s "$SLINKBIN/spin" "$ROOT/scaffold/shim/tool"
chk "the symlink is now the shim" $? 0
grep -q 'fake standalone' "$WORK/fakehome/spin"
chk "the fallback binary is left untouched" $? 0
FOREIGNBIN="$WORK/foreignbin"; mkdir -p "$FOREIGNBIN"
printf '#!/bin/bash\necho not a shim\n' > "$FOREIGNBIN/spin"
out=$(bash "$CLI" install-shim --bin-dir "$FOREIGNBIN" 2>&1); shim_rc=$?
chk "install-shim refuses a foreign spin" "$shim_rc" 1
grep -q 'refusing to replace' <<<"$out"
chk "the refusal says why" $? 0

# Cache-key spellings share one copy: a differently spelled pin of the
# same rev reuses the existing cache entry instead of duplicating it.
mkdir -p cache-reuse
cat > cache-reuse/pins.toml <<CONF
SPINEL_REV="1d26ef6f"
CONF
cat > cache-reuse/resolve.sh <<'SH'
source "$1/cli/toolchain.sh"
spinel_toolchain_ensure "$2/pins.toml"
SH
bash cache-reuse/resolve.sh "$ROOT" cache-reuse >/dev/null 2>&1
chk "a second pin spelling reuses the toolchain" $? 0
[[ ! -d "$XDG_CACHE_HOME/snails/spinel/1d26ef6f" ]]
chk "no duplicate cache entry for the same rev" $? 0

mkdir -p tc-nodir
cat > tc-nodir/pins.toml <<CONF
SNALS_REV="$PIN_REV"
CONF
mk_contract_app tcapp2
bash "$PINSNAILS/bin/snails" sync tcapp2 --pins tc-nodir/pins.toml > tc-nospinel.out 2>&1
chk "sync rejects a pins file without SPINEL_REV" $? 1
grep -q 'has no SPINEL_REV' tc-nospinel.out
chk "the missing toolchain rev is named" $? 0
[[ ! -d tc-nodir/.spinel ]]
chk "no toolchain is materialized without the rev" $? 0

# The engine comes from the pin, so a pin older than the toolchain
# contract syncs exactly as before — no materialization, announced. The
# snapshot is faithful: no resolver file in either location (cli/ or
# the pre-move scaffold/harness/), and the engine's sync script makes no
# reference to it.
OLDREPO="$WORK/predates-snails"
mkdir -p "$OLDREPO"
for p in bin cli scaffold runtime pins.toml; do cp -R "$ROOT/$p" "$OLDREPO/"; done
rm -f "$OLDREPO/scaffold/harness/toolchain.sh" "$OLDREPO/cli/toolchain.sh"
sed -i '/toolchain\.sh/d' "$OLDREPO/cli/sync-runtime.sh"
git -C "$OLDREPO" init -q
git -C "$OLDREPO" add -A
git -C "$OLDREPO" -c user.name=snails -c user.email=snails@test \
  commit -q --no-verify -m "core predates the toolchain contract"
OLD_REV="$(git -C "$OLDREPO" rev-parse HEAD)"
mkdir -p oldpin
cat > oldpin/pins.toml <<CONF
SPINEL_REV="1d26ef6"
SNALS_REV="$OLD_REV"
CONF
mk_contract_app oldapp
bash "$OLDREPO/bin/snails" sync oldapp --pins oldpin/pins.toml > old.out 2>&1
chk "sync with a pre-toolchain pin succeeds" $? 0
grep -q 'predates the spinel toolchain contract' old.out
chk "the pre-toolchain pin is announced" $? 0
[[ ! -d oldpin/.spinel ]]
chk "no toolchain is materialized for a pre-toolchain pin" $? 0

# 11. Interpreter contract — `sync`, `new`, and `verify-scaffold` must run
#     with a `ruby` that fails loudly shadowed on PATH: the CLI's scaffold
#     engines are shell scripts (the migration runner's rule, extended).
#     The pins.toml from case 4 would be discovered by the walk-up here.
rm -f pins.toml
NORUBY="$WORK/noruby"
mkdir -p "$NORUBY"
cat > "$NORUBY/ruby" <<'SH'
#!/bin/bash
echo "ruby must not be called by the CLI engines" >&2
exit 127
SH
chmod +x "$NORUBY/ruby"

mkdir -p shadow/$SNAILS_VENDOR_DIR
mk_contract_app shadow
PATH="$NORUBY:$PATH" bash "$CLI" sync shadow > shadow-sync.out 2>&1
chk "sync runs without ruby" $? 0
PATH="$NORUBY:$PATH" bash "$CLI" verify-scaffold shadow >/dev/null 2>&1
chk "verify-scaffold runs without ruby" $? 0
PATH="$NORUBY:$PATH" bash "$CLI" new shapenew > shadow-new.out 2>&1
chk "new runs without ruby" $? 0
if grep -q 'ruby must not be called' shadow-sync.out shadow-new.out; then
  chk "the ruby shadow was never reached" 1 0
else
  chk "the ruby shadow was never reached" 0 0
fi

# 12. verify-pins — the pin declaration gate (SNALS_REV restorable + the
#     SPINEL_REV pair record), with walk-up discovery and --pins.
#     PINSNAILS carries the transition shapes: commit A (PIN_REV) is an
#     old-layout rev (engine dir script/) whose pins.toml declares the
#     retired list — the pair
#     check reads its last token; commit C (SCALAR_REV) carries the
#     SPINEL_REV record; commit D (NODECL_REV) declares nothing. The CLI
#     tree is ahead of all three, so every check must read the PINNED
#     rev's record (git show), never the checkout's current value.
mkdir -p vp/app
cat > vp/pins.toml <<CONF
SPINEL_REV="1d26ef6"
SNALS_REV="$PIN_REV"
CONF
bash "$PINSNAILS/bin/snails" verify-pins vp/app > vp-ok.out 2>&1
chk "verify-pins ok via the retired list's last token" $? 0
grep -q 'pins ok (spinel=1d26ef6 snails=' vp-ok.out
chk "verify-pins prints the ok line" $? 0
if grep -q 'notice:' vp-ok.out; then vp_notice=1; else vp_notice=0; fi
chk "verify-pins default omits the ahead-of-pin notice" "$vp_notice" 0
if grep -q "renamed to scripts" vp-ok.out; then vp_listed=1; else vp_listed=0; fi
chk "verify-pins default notice stays one line" "$vp_listed" 0
bash "$PINSNAILS/bin/snails" verify-pins vp/app --verbose > vp-verbose.out 2>&1
chk "verify-pins --verbose passes" $? 0
grep -q "notice:" vp-verbose.out
chk "verify-pins --verbose adds the ahead-of-pin notice" $? 0
grep -q "renamed to scripts" vp-verbose.out
chk "verify-pins --verbose adds the commit list" $? 0

bash "$PINSNAILS/bin/snails" verify-pins --pins vp/pins.toml >/dev/null 2>&1
chk "verify-pins --pins" $? 0

# The declaration gate resolves the app root like every other command: a
# repository root that holds the app in src/ finds the pins file there.
mkdir -p vp-repo/.git vp-repo/src/config
: > vp-repo/src/config/database.rb
cat > vp-repo/src/pins.toml <<CONF
SPINEL_REV="1d26ef6"
SNALS_REV="$PIN_REV"
CONF
(cd vp-repo && bash "$PINSNAILS/bin/snails" pins check) > vp-repo.out 2>&1
chk "pins check resolves the src/ app from the repository root" $? 0
grep -q 'pins ok (spinel=1d26ef6 snails=' vp-repo.out
chk "pins check prints the ok line for the src/ app" $? 0

# The harness engines probe capability by running the subcommand's own
# help — exit 0 is the contract they gate on (an old CLI exits non-zero
# on the unknown command and is announced instead).
bash "$CLI" verify-pins -h >/dev/null 2>&1
chk "verify-pins -h exits 0 (the engines' capability probe)" $? 0

# The SPINEL_REV record shape: the pair is checked against the pinned
# rev's own declaration, which the CLI tree is ahead of.
cat > vp/record.toml <<CONF
SPINEL_REV="abc1234"
SNALS_REV="$SCALAR_REV"
CONF
bash "$PINSNAILS/bin/snails" verify-pins --pins vp/record.toml > vp-record.out 2>&1
chk "verify-pins ok on the SPINEL_REV record" $? 0
grep -q 'pins ok (spinel=abc1234 snails=' vp-record.out
chk "the ok line names the recorded rev" $? 0

# A mismatched pair names both revs and the pasteable repair.
cat > vp/bad-spinel.toml <<CONF
SPINEL_REV="deadbee"
SNALS_REV="$PIN_REV"
CONF
bash "$PINSNAILS/bin/snails" verify-pins --pins vp/bad-spinel.toml > vp-spinel.out 2>&1
chk "verify-pins fails on a spinel rev the pair does not declare" $? 1
grep -q 'is not the rev declared for SNALS_REV' vp-spinel.out
chk "the pair mismatch is named" $? 0
grep -q '(1d26ef6)' vp-spinel.out
chk "the pair mismatch names the declared rev" $? 0
grep -q 'set SPINEL_REV="1d26ef6" in vp/bad-spinel.toml' vp-spinel.out
chk "the repair names the pasteable value and the file" $? 0
bash "$PINSNAILS/bin/snails" verify-pins vp --pins vp/bad-spinel.toml > vp-spinel-root.out 2>&1
chk "the same mismatch with an app_root still fails" $? 1
grep -q "run: snails sync vp" vp-spinel-root.out
chk "the repair names the sync target when the caller provided one" $? 0

# Bumping SNALS_REV without bumping SPINEL_REV is the repair the gate
# exists for: the expected value is the new rev's declaration.
cat > vp/stale-pair.toml <<CONF
SPINEL_REV="1d26ef6"
SNALS_REV="$SCALAR_REV"
CONF
bash "$PINSNAILS/bin/snails" verify-pins --pins vp/stale-pair.toml > vp-stale.out 2>&1
chk "verify-pins fails a core bump without the spinel bump" $? 1
grep -q '(abc1234)' vp-stale.out
chk "the stale pair names the rev to adopt" $? 0

# A pinned rev that declares nothing is loud, not a skip.
cat > vp/nodecl.toml <<CONF
SPINEL_REV="abc1234"
SNALS_REV="$NODECL_REV"
CONF
bash "$PINSNAILS/bin/snails" verify-pins --pins vp/nodecl.toml > vp-nodecl.out 2>&1
chk "verify-pins fails when the pinned rev declares no spinel rev" $? 1
grep -q 'carries no spinel pin declaration' vp-nodecl.out
chk "the missing declaration is named" $? 0

cat > vp/no-snals.toml <<CONF
SPINEL_REV="1d26ef6"
CONF
bash "$PINSNAILS/bin/snails" verify-pins --pins vp/no-snals.toml > vp-nosnals.out 2>&1
chk "verify-pins fails without SNALS_REV" $? 1
grep -q 'SNALS_REV is not declared' vp-nosnals.out
chk "the missing SNALS_REV is named" $? 0

cat > vp/no-spinel.toml <<CONF
SNALS_REV="$PIN_REV"
CONF
bash "$PINSNAILS/bin/snails" verify-pins --pins vp/no-spinel.toml > vp-nospinel.out 2>&1
chk "verify-pins fails without SPINEL_REV" $? 1
grep -q 'SPINEL_REV is not declared' vp-nospinel.out
chk "the missing SPINEL_REV is named" $? 0

cat > vp/unknown-rev.toml <<CONF
SPINEL_REV="1d26ef6"
SNALS_REV="deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
CONF
bash "$PINSNAILS/bin/snails" verify-pins --pins vp/unknown-rev.toml >/dev/null 2>&1
chk "verify-pins fails on an unknown SNALS_REV" $? 1

# The declaration format gate: an abbreviated SNALS_REV names the same
# commit everywhere only when it is full 40-hex (a dist release tag and
# asset name derive from the full form), so the gate refuses it with the
# expand-and-record repair before any mode logic runs.
cat > vp/abbrev.toml <<CONF
SPINEL_REV="1d26ef6"
SNALS_REV="${PIN_REV:0:7}"
CONF
bash "$PINSNAILS/bin/snails" verify-pins --pins vp/abbrev.toml > vp-abbrev.out 2>&1
chk "verify-pins fails on an abbreviated SNALS_REV" $? 1
grep -q 'is not a full 40-hex rev' vp-abbrev.out
chk "the abbreviated pin is named" $? 0
grep -q "run 'git rev-parse ${PIN_REV:0:7}'" vp-abbrev.out
chk "the repair names the expand command" $? 0

# The release channel: a vX.Y.Z pin resolves through its tag to the
# tagged commit — the same gate, two declaration forms. The tag points
# at the old-layout fixture commit: its pins.toml carries the retired
# list, so this pin also exercises the pair record's compat reader.
gitsnap tag v9.9.9 "$PIN_REV"
cat > vp/version.toml <<CONF
SPINEL_REV="1d26ef6"
SNALS_REV="v9.9.9"
CONF
bash "$PINSNAILS/bin/snails" verify-pins --pins vp/version.toml > vp-version.out 2>&1
chk "verify-pins passes a vX.Y.Z pin resolved through its tag" $? 0
grep -q 'pins ok (spinel=1d26ef6 snails=v9.9.9)' vp-version.out
chk "the ok line shows the declared version" $? 0

# A version tag that does not exist is loud, with the tag repair.
cat > vp/noversion.toml <<CONF
SPINEL_REV="abc1234"
SNALS_REV="v0.0.0"
CONF
bash "$PINSNAILS/bin/snails" verify-pins --pins vp/noversion.toml > vp-noversion.out 2>&1
chk "verify-pins fails an unknown vX.Y.Z" $? 1
grep -q 'names no tag in this snails checkout' vp-noversion.out
chk "the unknown version names the missing tag" $? 0
grep -q "run 'git fetch --tags'" vp-noversion.out
chk "the repair suggests fetching tags" $? 0

# A version-like value that is not a version (v1.0) is refused by the
# format gate, which names both accepted forms.
cat > vp/badversion.toml <<CONF
SPINEL_REV="abc1234"
SNALS_REV="v1.0"
CONF
bash "$PINSNAILS/bin/snails" verify-pins --pins vp/badversion.toml > vp-badversion.out 2>&1
chk "verify-pins fails a malformed version" $? 1
grep -q 'is not a full 40-hex rev or a vX.Y.Z version' vp-badversion.out
chk "the format gate names both accepted forms" $? 0

# sync vendors the tagged commit through the version pin — the resolved
# rev keys on, the declared version is what the result reports.
mk_contract_app vapp
cat > vapp-pins.toml <<CONF
SPINEL_REV="1d26ef6"
SNALS_REV="v9.9.9"
CONF
bash "$PINSNAILS/bin/snails" sync vapp --pins vapp-pins.toml > vapp-sync.txt 2>&1
chk "sync vendors a vX.Y.Z pin through its tag" $? 0
mkdir vapp-exp
git -C "$PINSNAILS" archive "$PIN_REV" -- runtime | tar -x -C vapp-exp
compare_core vapp-exp/runtime vapp/$SNAILS_VENDOR_DIR
chk "the vendored core is the tagged commit's" $? 0
grep -q '^  VERSION = "v9.9.9"$' vapp/$SNAILS_VENDOR_DIR/snails/version.rb
chk "sync stamps the declared version" $? 0
grep -q "^  REV = \"$PIN_REV\"$" vapp/$SNAILS_VENDOR_DIR/snails/version.rb
chk "sync stamps the tagged revision" $? 0
grep -q 'synced (core v9.9.9, spinel 1d26ef6)' vapp-sync.txt
chk "the sync result names the declared version" $? 0

mkdir -p vp-none/repo/src
touch vp-none/repo/.git
bash "$PINSNAILS/bin/snails" verify-pins vp-none/repo/src >/dev/null 2>&1
chk "verify-pins fails without a pins file" $? 1
bash "$PINSNAILS/bin/snails" verify-pins --pins vp-none/missing.toml >/dev/null 2>&1
chk "verify-pins fails on a missing --pins file" $? 1

# 13. gen-require-all — the generator is a CLI engine (no app-side copy):
#     the seed's region matches its own scan, a new controller makes
#     --check stale, and regeneration picks it up.
bash "$CLI" gen-require-all app --check >/dev/null 2>&1
chk "gen-require-all --check on a fresh app" $? 0
mkdir -p app/app/controllers
echo 'class LateController; end' > app/app/controllers/late_controller.rb
bash "$CLI" gen-require-all app --check >/dev/null 2>&1
chk "gen-require-all --check detects staleness" $? 1
bash "$CLI" gen-require-all app >/dev/null 2>&1
chk "gen-require-all regenerates" $? 0
grep -q 'require_relative "../app/controllers/late_controller"' app/gen/controllers.rb
chk "the new controller is in the require list" $? 0
bash "$CLI" gen-require-all >/dev/null 2>&1
chk "gen-require-all usage error" $? 2

# 14. gen-route-helpers — the generator is a CLI engine (no app-side copy):
#     the CLI dispatch and --check wiring. The row grammar, name derivation,
#     collision refusal, and --check contract belong to
#     test-gen-route-helpers.sh, which runs them against the real parser;
#     here the fake toolchain answers with the scaffold's canned AST.
mkdir -p ghapp/config ghapp/gen
printf 'SPINEL_REV="%s"\n' "$SPINEL_REV" > ghapp/pins.toml
cp "$ROOT/scaffold/new/config/routes.rb" ghapp/config/routes.rb
bash "$CLI" gen-route-helpers ghapp >/dev/null 2>&1
chk "gen-route-helpers generates" $? 0
grep -q 'def self.up_path' ghapp/gen/route_helpers.rb
chk "the scaffold route has a helper" $? 0
bash "$CLI" gen-route-helpers ghapp --check >/dev/null 2>&1
chk "gen-route-helpers --check on a fresh app" $? 0
printf '\n# drift\n' >> ghapp/gen/route_helpers.rb
bash "$CLI" gen-route-helpers ghapp --check >/dev/null 2>&1
chk "gen-route-helpers --check detects staleness" $? 1
bash "$CLI" gen-route-helpers ghapp >/dev/null 2>&1
chk "gen-route-helpers regenerates" $? 0
bash "$CLI" gen-route-helpers >/dev/null 2>&1
chk "gen-route-helpers usage error" $? 2

# 15. harness — the app-target runners are CLI engines (no app-side
#     copy): usage covers both subcommands, an unknown subcommand and a
#     missing app_root are refused, and an app without harness/ fails
#     loudly instead of running something else.
bash "$CLI" harness >/dev/null 2>&1
chk "harness without a subcommand prints help" $? 0
bash "$CLI" harness bogus ghapp >/dev/null 2>&1
chk "harness refuses an unknown subcommand" $? 2
bash "$CLI" harness test >/dev/null 2>&1
chk "harness test without a resolvable app_root" $? 2
bash "$CLI" harness test ghapp >/dev/null 2>&1
chk "harness test without harness/ fails loudly" $? 1
bash "$CLI" harness dev ghapp >/dev/null 2>&1
chk "harness dev without harness/ fails loudly" $? 1
bash "$CLI" help 2>&1 | grep -q '^  build-image'
chk "overview lists build-image" $? 0
bash "$CLI" help 2>&1 | grep -q '^  build-binary'
chk "overview lists build-binary" $? 0
bash "$CLI" help 2>&1 | grep -q '^  compose'
chk "overview lists compose" $? 0
bash "$CLI" help --all 2>&1 | grep -q "harness test|dev"
chk "help --all lists harness test|dev" $? 0
bash "$CLI" help --all 2>&1 | grep -q "harness test"
chk "help --all lists harness" $? 0
# The core-check escape hatch is a flag, not an env: its discoverability
# lives in the command help (an unexported flag is the whole point).
bash "$CLI" help harness test 2>&1 | grep -q -- "--force"
chk "command help documents the core-check --force" $? 0
# The feature generator keeps the `generate` spelling and its alias
# in the overview; `generate` alone lists the generators.
bash "$CLI" help 2>&1 | grep -q 'generate.*(g)'
chk "overview documents the generate alias" $? 0
bash "$CLI" generate 2>&1 | grep -q 'job_queue'
chk "generate lists job_queue" $? 0
bash "$CLI" generate bogus >/dev/null 2>&1
chk "generate refuses an unknown generator" $? 2
bash "$CLI" generate >/dev/null 2>&1
chk "generate without a generator lists generators" $? 0
# The declaration gate is capability-probed: a CLI tree that predates
# verify-pins (an old dist on PATH) is announced and skipped, never
# crashed on — the toolchain step below it then reports its own failure
# instead of the gate pretending it ran.
OLDCLI="$WORK/oldcli/snails"
mkdir -p "$(dirname "$OLDCLI")"
cat > "$OLDCLI" <<'SH'
#!/bin/bash
echo "unknown command: $1" >&2
exit 2
SH
chmod +x "$OLDCLI"
mkdir -p oldcli-app/harness
cat > oldcli-app/pins.toml <<CONF
SPINEL_REV="1d26ef6"
SNALS_REV="$PIN_REV"
CONF
out=$(SNAILS_CLI="$OLDCLI" bash "$ROOT/cli/harness-test.sh" oldcli-app 2>&1)
grep -q 'predates verify-pins' <<<"$out"
chk "an old CLI is announced, not crashed on" $? 0

# 16. pins-path — the pins file location as a one-line result: the app root
#     resolves the same way sync and verify-pins resolve it, and the same
#     walk finds the file.
mkdir -p pp/src pp/config
: > pp/config/database.rb
echo 'SPINEL_REV="1d26ef6"' > pp/pins.toml
expected="$(cd pp && pwd)/pins.toml"
out="$(bash "$CLI" pins-path pp/src)"
chk "pins-path finds the pins file above the start directory" $? 0
[[ $out == "$expected" ]]
chk "pins-path prints exactly that path" $? 0
# The marker survives the command substitution, so only a real newline
# in the output makes the comparison hold.
out="$(bash "$CLI" pins-path pp/src; printf x)"
[[ $out == "$expected"$'\n'x ]]
chk "pins-path ends its line with a newline" $? 0
out="$( (cd pp && bash "$CLI" pins-path) )"
[[ $out == "$expected" ]]
chk "pins-path defaults to the current directory" $? 0
mkdir -p legacy/src
echo 'SPINEL_REV=1d26ef6' > legacy/src/pins.conf
bash "$CLI" pins-path legacy/src > legacy.out 2>&1
chk "pins-path refuses the retired pins.conf name" $? 1
grep -q 'no pins file at or above' legacy.out
chk "the refusal is the one-line pins-path message" $? 0

# The walk stops at the .git boundary, so a pins file above the
# repository is never this project's pins file — and the refusal stays
# the one line verify-pins reports.
mkdir -p bounded/repo/src
touch bounded/repo/.git
echo 'SPINEL_REV="1d26ef6"' > bounded/pins.toml
bash "$CLI" pins-path bounded/repo/src > bounded.out 2>&1
chk "pins-path refuses a pins file above the .git boundary" $? 1
grep -q 'no pins file at or above' bounded.out
chk "pins-path names the missing pins file" $? 0
[[ $(grep -c . bounded.out) -eq 1 ]]
chk "pins-path keeps the refusal to one line" $? 0

bash "$CLI" pins-path -h >/dev/null 2>&1
chk "pins-path -h exits 0" $? 0
bash "$CLI" pins-path --bogus >/dev/null 2>&1
chk "pins-path rejects an unknown flag" $? 2

echo "----"
echo "pass=$pass fail=$fail"
if ((fail > 0)); then
  exit 1
fi
exit 0
