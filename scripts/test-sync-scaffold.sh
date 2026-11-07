#!/bin/bash
# Regression test for the sync-runtime engine and the scaffold contract
# gate — the sync/scaffold checks that predate the small harness.
# Consumer-side expected outputs (bin/native-test etc.) stay separate.
#
# Usage: bash scripts/test-sync-scaffold.sh
# Exit: 0=all cases pass, 1=failure.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../cli/vendor-dir.sh
source "$ROOT/cli/vendor-dir.sh"
BOOT="$ROOT/runtime/boot.rb"
BOOT_ALL="$ROOT/runtime/boot/all.rb"
MAIN="$ROOT/scaffold/main.rb"
SR="$ROOT/cli/sync-runtime.sh"
V="$ROOT/cli/verify-scaffold.sh"
SEED="$ROOT/scaffold/seed/gen"
CONFIG_SEED="$ROOT/scaffold/seed/config/application.rb"
BOOT_PROFILE_SEED="$ROOT/scaffold/seed/config/boot.rb"
ENV_TEMPLATE="$ROOT/scaffold/new/config/environment.rb"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
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

# 1. sync-runtime: core replaced, no app boot created, and a retired app
#    boot is refused before the core is touched.
mkdir -p app/$SNAILS_VENDOR_DIR
echo old > app/$SNAILS_VENDOR_DIR/old.rb
bash "$SR" app >/dev/null
chk "sync-runtime replaces the core" $? 0
[[ ! -f app/$SNAILS_VENDOR_DIR/old.rb ]]
chk "vendored core replaced" $? 0
[[ -f app/$SNAILS_VENDOR_DIR/boot.rb && ! -e app/boot.rb ]]
chk "sync-runtime vendors the core boot and writes no app boot" $? 0
grep -q '^  VERSION = "unknown"$' app/$SNAILS_VENDOR_DIR/snails/version.rb
chk "sync-runtime leaves the default version when no stamp is supplied" $? 0

# A sync with a resolved core version stamps the vendored metadata — this is
# the checkout path the CLI takes; a dist artifact already carries it.
mkdir -p stamped
SNAILS_VERSION="v9.9.9" SNAILS_REV="deadbeef" bash "$SR" stamped >/dev/null
chk "sync-runtime accepts version metadata" $? 0
grep -q '^  VERSION = "v9.9.9"$' stamped/$SNAILS_VENDOR_DIR/snails/version.rb
chk "sync-runtime stamps the version" $? 0
grep -q '^  REV = "deadbeef"$' stamped/$SNAILS_VENDOR_DIR/snails/version.rb
chk "sync-runtime stamps the revision" $? 0

mkdir -p retired/$SNAILS_VENDOR_DIR
echo old > retired/$SNAILS_VENDOR_DIR/old.rb
printf '# retired app boot\n' > retired/boot.rb
bash "$SR" retired > retired.out 2>&1
chk "sync-runtime refuses a retired app boot" $? 1
grep -q 'boot.rb is retired' retired.out
chk "the refusal names the retired boot" $? 0
[[ -f retired/$SNAILS_VENDOR_DIR/old.rb ]]
chk "the refusal writes nothing" $? 0

mk_contract_app() {
  # Model a consumer app tree: the scaffold-owned server entry + the
  # vendored core boot + the require-all files (the eight folder groups,
  # the generated path helpers, and the model-column attach file) whose
  # controllers seed already loads the controllers + a routes table that
  # declares GET /up and nothing else. The health controller is vendored
  # core (snails-core/) — the app carries no copy, and it carries no
  # app-level boot.rb.
  mkdir -p "$1/config" "$1/gen" "$1/$SNAILS_VENDOR_DIR" "$1/$SNAILS_VENDOR_DIR/snails" "$1/$SNAILS_VENDOR_DIR/boot"
  cp "$MAIN" "$1/main.rb"
  cp "$BOOT" "$1/$SNAILS_VENDOR_DIR/boot.rb"
  cp "$BOOT_ALL" "$1/$SNAILS_VENDOR_DIR/boot/all.rb"
  printf 'require_relative "../%s/database/sqlite"\n' "$SNAILS_VENDOR_DIR" > "$1/config/database.rb"
  cp "$ROOT/runtime/snails/health_controller.rb" "$1/$SNAILS_VENDOR_DIR/snails/health_controller.rb"
  cp "$CONFIG_SEED" "$1/config/application.rb"
  cp "$BOOT_PROFILE_SEED" "$1/config/boot.rb"
  cp "$ENV_TEMPLATE" "$1/config/environment.rb"
  cp "$ROOT/scaffold/seed/config/codegen.rb" "$1/config/codegen.rb"
  for name in lib controllers helpers mailers models model_columns forms jobs services route_helpers; do
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

# 7. Scaffold contract: server entry byte match + core boot present + no
#    app boot, `GET /up`, no stale health require + single core definition
#    + core-default files present — any violation fails
entry_lines=$(grep -Ec '^require_relative "\.\./config/boot"$' "$BOOT")
chk "the boot entry requires the app profile" "$entry_lines" 1
req_lines=$(grep -Ec '^require_relative "\.\./\.\./config/codegen"$' "$BOOT_ALL")
chk "the all profile requires the app load list" "$req_lines" 1
gen_lines=$(grep -Ec '^require_relative "\.\./\.\./gen/' "$BOOT_ALL")
chk "the all profile carries no per-folder require" "$gen_lines" 0
action_index_lines=$(grep -Ec '^require_relative "\.\./(action_dispatch|action_controller)"$' "$BOOT_ALL")
chk "the all profile requires the action indexes" "$action_index_lines" 2
action_child_lines=$(grep -Ec '^require_relative "\.\./action_(dispatch|controller)/' "$BOOT_ALL")
chk "the all profile carries no action per-folder require" "$action_child_lines" 0
profile_lines=$(grep -cF "require_relative \"../$SNAILS_VENDOR_DIR/boot/all\"" "$BOOT_PROFILE_SEED")
chk "the app profile seed selects all" "$profile_lines" 1

mk_contract_app c-good
bash "$V" c-good >/dev/null
chk "contract satisfied" $? 0

mk_contract_app c-nobootprofile
rm c-nobootprofile/config/boot.rb
bash "$V" c-nobootprofile > c-nobootprofile.out 2>&1
chk "missing config/boot.rb fails" $? 1
grep -q 'config/boot.rb: missing' c-nobootprofile.out
chk "the missing profile is named" $? 0

mk_contract_app c-nobootall
rm c-nobootall/$SNAILS_VENDOR_DIR/boot/all.rb
bash "$V" c-nobootall > c-nobootall.out 2>&1
chk "missing selected boot profile fails" $? 1
grep -q "$SNAILS_VENDOR_DIR/boot/all.rb: missing" c-nobootall.out
chk "the missing profile target is named" $? 0

# A v1 app keeps the flat boot entry and has no config/boot.rb; the newer
# CLI must not demand a profile from it.
mk_contract_app c-legacyboot
printf 'require_relative "../config/environment"\n' > c-legacyboot/$SNAILS_VENDOR_DIR/boot.rb
rm c-legacyboot/config/boot.rb
bash "$V" c-legacyboot >/dev/null 2>&1
chk "a legacy flat boot passes without a profile" $? 0

mk_contract_app c-twoprofiles
printf 'require_relative "../%s/boot/all"\nrequire_relative "../%s/boot/all"\n' "$SNAILS_VENDOR_DIR" "$SNAILS_VENDOR_DIR" > c-twoprofiles/config/boot.rb
bash "$V" c-twoprofiles >/dev/null 2>&1
chk "a profile file with two selections fails" $? 1

# The GET /up row reads as Route.new or a verb helper — including the
# paren helper form, the shape a core-helper app writes.
mk_contract_app c-paren
sed -i 's|ActionDispatch::Router::Route.new("GET", "/up", Snails::HealthController, :show)|get("/up", Snails::HealthController, :show)|' c-paren/config/routes.rb
bash "$V" c-paren >/dev/null 2>&1
chk "paren verb helper /up passes" $? 0

mk_contract_app c-bare
sed -i 's|ActionDispatch::Router::Route.new("GET", "/up", Snails::HealthController, :show)|get "/up", Snails::HealthController, :show|' c-bare/config/routes.rb
bash "$V" c-bare >/dev/null 2>&1
chk "bare verb helper /up passes" $? 0

mk_contract_app c-noup
sed -i 's|"/up"|"/nope"|' c-noup/config/routes.rb
bash "$V" c-noup >/dev/null 2>&1
chk "no /up route fails" $? 1

# The health definition is core-owned: an app-side copy — the retired
# scaffold file or any definition under app/** — is drift, and a stale
# require names a file that no longer exists.
mk_contract_app c-staleapp
mkdir -p c-staleapp/app/controllers/snails
printf 'module Snails\n  class HealthController < ActionController::API\n  end\nend\n' > c-staleapp/app/controllers/snails/health_controller.rb
bash "$V" c-staleapp >/dev/null 2>&1
chk "the retired app-side copy fails" $? 1

mk_contract_app c-dupapp
mkdir -p c-dupapp/app/controllers
echo 'class HealthController; end' > c-dupapp/app/controllers/other_controller.rb
bash "$V" c-dupapp >/dev/null 2>&1
chk "an app definition at another path fails" $? 1

mk_contract_app c-stalereq
sed -i '1i require_relative "../app/controllers/snails/health_controller"' c-stalereq/gen/controllers.rb
bash "$V" c-stalereq >/dev/null 2>&1
chk "stale health require in gen/controllers.rb fails" $? 1

mk_contract_app c-stalereq-routes
sed -i '1i require_relative "../app/controllers/snails/health_controller"' c-stalereq-routes/config/routes.rb
bash "$V" c-stalereq-routes >/dev/null 2>&1
chk "stale health require in config/routes.rb fails" $? 1

mk_contract_app c-coremissing
rm c-coremissing/$SNAILS_VENDOR_DIR/snails/health_controller.rb
bash "$V" c-coremissing >/dev/null 2>&1
chk "missing core definition fails" $? 1

mk_contract_app c-dupcore
echo 'class HealthController; end' > c-dupcore/$SNAILS_VENDOR_DIR/other_controller.rb
bash "$V" c-dupcore >/dev/null 2>&1
chk "second core definition fails" $? 1

# The server entry is scaffold-owned byte-for-byte: app code (or a
# re-copied core block) in main.rb is drift, not a customization.
mk_contract_app c-maindrift
echo '# APP CODE' >> c-maindrift/main.rb
bash "$V" c-maindrift >/dev/null 2>&1
chk "drifted main.rb fails" $? 1

mk_contract_app c-mainmissing
rm c-mainmissing/main.rb
bash "$V" c-mainmissing >/dev/null 2>&1
chk "missing main.rb fails" $? 1

# The boot chain is core-owned: an app-level boot.rb is a retired copy,
# and the vendored core must carry snails-core/boot.rb.
mk_contract_app c-strayboot
printf '# retired app boot\n' > c-strayboot/boot.rb
bash "$V" c-strayboot >/dev/null 2>&1
chk "a stray app boot.rb fails" $? 1

mk_contract_app c-nocoreboot
rm c-nocoreboot/$SNAILS_VENDOR_DIR/boot.rb
bash "$V" c-nocoreboot >/dev/null 2>&1
chk "missing snails-core/boot.rb fails" $? 1

# A main.rb still requiring the retired app boot gets the migration line,
# not just a bare byte diff.
mk_contract_app c-retiredmain
sed -i 's|require_relative "snails-core/boot"|require_relative "boot"|' c-retiredmain/main.rb
bash "$V" c-retiredmain > c-retiredmain.out 2>&1
chk "a main.rb on the retired boot fails" $? 1
grep -q 'retired app boot' c-retiredmain.out
chk "the main.rb message names the retired boot" $? 0

# The harness target shares the core boot; its old app-boot require is
# named as a stale require.
mk_contract_app c-harnessboot
mkdir -p c-harnessboot/harness
printf 'require_relative "../boot"\n' > c-harnessboot/harness/boot.rb
bash "$V" c-harnessboot > c-harnessboot.out 2>&1
chk "a harness boot on the retired app boot fails" $? 1
grep -q 'harness/boot.rb: requires the retired app boot' c-harnessboot.out
chk "the harness message names the retired require" $? 0

mk_contract_app c-noenv
rm c-noenv/config/environment.rb
bash "$V" c-noenv >/dev/null 2>&1
chk "missing config/environment.rb fails" $? 1

mk_contract_app c-noreqall
rm c-noreqall/gen/jobs.rb c-noreqall/gen/services.rb c-noreqall/gen/forms.rb
bash "$V" c-noreqall >/dev/null 2>&1
chk "missing core-default require-all file fails" $? 1

mk_contract_app c-noconfig
rm c-noconfig/config/application.rb
bash "$V" c-noconfig >/dev/null 2>&1
chk "missing config/application.rb fails" $? 1

# 8. Sync wiring: an app tree gets the contract verified; a core-only
#    tree (--check staging) is skipped
mk_contract_app s-good
bash "$SR" s-good >/dev/null
chk "sync verifies app tree contract" $? 0
[[ ! -e s-good/boot.rb && -f s-good/$SNAILS_VENDOR_DIR/boot.rb ]]
chk "sync leaves the boot in the vendored core only" $? 0

mk_contract_app s-bad
sed -i 's|"/up"|"/nope"|' s-bad/config/routes.rb
bash "$SR" s-bad >/dev/null 2>&1
chk "sync fails without /up" $? 1

# Missing require-all files are created by sync from the scaffold seed
# (create once — contents are app-owned afterwards)
mk_contract_app s-seed
rm s-seed/gen/jobs.rb s-seed/gen/services.rb s-seed/gen/forms.rb
bash "$SR" s-seed >/dev/null
chk "sync creates missing require-all files" $? 0
[[ -f s-seed/gen/jobs.rb && -f s-seed/gen/services.rb && -f s-seed/gen/forms.rb ]]
chk "seed files exist after sync" $? 0
grep -q 'Loads every ActiveJob subclass' s-seed/gen/jobs.rb
chk "seed content installed" $? 0

mkdir -p s-rt
bash "$SR" s-rt >/dev/null 2>&1
chk "sync skips core-only tree" $? 0

# The app config reopen, the app environment, and the boot profile are
# seeded once when missing — and an existing file is never rewritten
# (app-owned).
mk_contract_app s-config-seed
rm s-config-seed/config/application.rb
bash "$SR" s-config-seed >/dev/null
chk "sync seeds missing config/application.rb" $? 0
grep -q 'def app_name' s-config-seed/config/application.rb
chk "config seed content installed" $? 0

mk_contract_app s-config-keep
echo '# APP CONFIG' >> s-config-keep/config/application.rb
bash "$SR" s-config-keep >/dev/null
chk "sync keeps an existing config/application.rb" $? 0
grep -q '# APP CONFIG' s-config-keep/config/application.rb
chk "existing config kept (app-owned)" $? 0

mk_contract_app s-env-seed
rm s-env-seed/config/environment.rb
bash "$SR" s-env-seed >/dev/null
chk "sync seeds missing config/environment.rb" $? 0
grep -Fq 'Snails.time_zone = "UTC"' s-env-seed/config/environment.rb && grep -Fq 'Snails.app.secret_key_base' s-env-seed/config/environment.rb && ! grep -q 'LocalSecret' s-env-seed/config/environment.rb
chk "environment seed content installed (standard key reader, no local secret)" $? 0

mk_contract_app s-env-keep
echo '# APP ENV' >> s-env-keep/config/environment.rb
bash "$SR" s-env-keep >/dev/null
chk "sync keeps an existing config/environment.rb" $? 0
grep -q '# APP ENV' s-env-keep/config/environment.rb
chk "existing environment kept (app-owned)" $? 0

mk_contract_app s-boot-seed
rm s-boot-seed/config/boot.rb
bash "$SR" s-boot-seed >/dev/null
chk "sync seeds missing config/boot.rb" $? 0
grep -q "^require_relative \"\.\./$SNAILS_VENDOR_DIR/boot/all\"$" s-boot-seed/config/boot.rb
chk "boot profile seed content installed" $? 0

mk_contract_app s-boot-keep
echo '# APP BOOT' >> s-boot-keep/config/boot.rb
bash "$SR" s-boot-keep >/dev/null
chk "sync keeps an existing config/boot.rb" $? 0
grep -q '# APP BOOT' s-boot-keep/config/boot.rb
chk "existing boot profile kept (app-owned)" $? 0

# DB adapter: the database configuration is the app's config/database.rb — app-owned,
# never touched by sync, and the vendored core carries both backends
# with no database configuration, so it is byte-identical across adapters. A tree without
# the entry is seeded once from the retired DB env (sqlite default); a tree
# still carrying the retired name (config/db.rb) is migrated below.
mk_contract_app s-adapter-a
mk_contract_app s-adapter-b
printf 'require_relative "../%s/database/sqlite"\n' "$SNAILS_VENDOR_DIR" > s-adapter-a/config/database.rb
printf 'require_relative "../%s/database/postgresql"\n' "$SNAILS_VENDOR_DIR" > s-adapter-b/config/database.rb
DB=pg bash "$SR" s-adapter-a >/dev/null
bash "$SR" s-adapter-b >/dev/null
grep -Fq "require_relative \"../$SNAILS_VENDOR_DIR/database/sqlite\"" s-adapter-a/config/database.rb && grep -Fq "require_relative \"../$SNAILS_VENDOR_DIR/database/postgresql\"" s-adapter-b/config/database.rb
chk "sync leaves the app database configuration alone" $? 0
[[ ! -e s-adapter-a/$SNAILS_VENDOR_DIR/database.rb ]]
chk "vendored core carries no database configuration" $? 0
diff -r s-adapter-a/$SNAILS_VENDOR_DIR s-adapter-b/$SNAILS_VENDOR_DIR >/dev/null
chk "vendored core is byte-identical across adapters" $? 0
grep -q 'SQLite-via-libsqlite3-FFI' s-adapter-a/$SNAILS_VENDOR_DIR/database/sqlite.rb
chk "sqlite backend shipped" $? 0
grep -q 'PostgreSQL via libpq FFI' s-adapter-a/$SNAILS_VENDOR_DIR/database/postgresql.rb
chk "pg backend shipped" $? 0

# A tree without the database configuration is seeded once — the retired DB env names
# the adapter, sqlite is the default, and the seeded file is app-owned
# afterwards.
mk_contract_app s-adapter-seed-pg
rm s-adapter-seed-pg/config/database.rb
DB=pg bash "$SR" s-adapter-seed-pg >/dev/null
chk "sync seeds a missing database configuration from DB=" $? 0
grep -Fq "require_relative \"../$SNAILS_VENDOR_DIR/database/postgresql\"" s-adapter-seed-pg/config/database.rb
chk "seed names the pg backend" $? 0
grep -q 'config/database' s-adapter-seed-pg/config/database.rb
chk "seed carries the new template text" $? 0

mk_contract_app s-adapter-seed-default
rm s-adapter-seed-default/config/database.rb
bash "$SR" s-adapter-seed-default >/dev/null
grep -Fq "require_relative \"../$SNAILS_VENDOR_DIR/database/sqlite\"" s-adapter-seed-default/config/database.rb
chk "sync seeds a missing database configuration as sqlite" $? 0

# The retired configuration name (config/db.rb) is migrated in place: the
# file is renamed, the anchored require line is rewritten from the adapter
# the old line named, and the rest of the app-owned file is preserved.
mk_contract_app s-adapter-migrate
rm s-adapter-migrate/config/database.rb
printf '# app comment kept\nrequire_relative "../runtime/db_postgresql"\n' > s-adapter-migrate/config/db.rb
bash "$SR" s-adapter-migrate >/dev/null
chk "sync migrates the retired database configuration" $? 0
[[ ! -e s-adapter-migrate/config/db.rb && -f s-adapter-migrate/config/database.rb ]]
chk "retired name is gone, new name exists" $? 0
grep -Fq "require_relative \"../$SNAILS_VENDOR_DIR/database/postgresql\"" s-adapter-migrate/config/database.rb
chk "migration keeps the adapter named by the old require" $? 0
grep -q '# app comment kept' s-adapter-migrate/config/database.rb
chk "migration preserves the app comment" $? 0

# Both names present, or a retired file with no anchored require: loud.
mk_contract_app s-adapter-both
printf 'require_relative "../runtime/db_sqlite"\n' > s-adapter-both/config/db.rb
bash "$SR" s-adapter-both >/dev/null 2>&1
chk "both configuration names fails" $? 1

mk_contract_app s-adapter-unanchored
rm s-adapter-unanchored/config/database.rb
printf '# no require here\n' > s-adapter-unanchored/config/db.rb
bash "$SR" s-adapter-unanchored >/dev/null 2>&1
chk "retired entry without an anchored require fails" $? 1

# A missing database configuration is still the scaffold contract's standalone
# business: verify-scaffold alone (no sync seed) fails loudly — and a
# stray file under the retired name is an error there too.
mk_contract_app c-noadapter
rm c-noadapter/config/database.rb
bash "$V" c-noadapter >/dev/null 2>&1
chk "missing config/database.rb fails the contract" $? 1

mk_contract_app c-retired-name
printf 'require_relative "../runtime/db_sqlite"\n' > c-retired-name/config/db.rb
bash "$V" c-retired-name >/dev/null 2>&1
chk "a stray config/db.rb fails the contract" $? 1

# 9. Interpreter contract: both engines are shell-only. With a `ruby` that
#    fails loudly shadowed on PATH each one still does its whole job — the
#    same rule the migration runner follows.
NORUBY="$WORK/noruby"
mkdir -p "$NORUBY"
cat > "$NORUBY/ruby" <<'SH'
#!/bin/bash
echo "ruby must not be called by the CLI engines" >&2
exit 127
SH
chmod +x "$NORUBY/ruby"

mk_contract_app c-noruby
PATH="$NORUBY:$PATH" bash "$V" c-noruby >/dev/null 2>&1
chk "verify-scaffold runs without ruby" $? 0

PATH="$NORUBY:$PATH" bash "$SR" c-noruby >/dev/null 2>&1
chk "sync-runtime runs without ruby" $? 0

# 10. Runner step 0 contract: the pin declaration gate is CLI-owned — each
#     engine probes verify-pins capability and runs it for the spin root
#     (announcing a tree without pins). The app check-pins hook is
#     retired: no engine carries the probe (app-specific checks live in
#     the app-owned bin/test/bin/dev wrappers).
for eng in harness-test harness-dev; do
  grep -q '"$CLI" verify-pins "$SPIN_ROOT"' "$ROOT/cli/$eng.sh"
  chk "$eng runs the CLI pin gate" $? 0
  grep -q 'verify-pins -h' "$ROOT/cli/$eng.sh"
  chk "$eng probes verify-pins capability" $? 0
  grep -q 'no pins file above' "$ROOT/cli/$eng.sh"
  chk "$eng announces a tree without pins" $? 0
  if grep -q 'check-pins.rb' "$ROOT/cli/$eng.sh"; then eng_hook=1; else eng_hook=0; fi
  chk "$eng carries no retired check-pins probe" "$eng_hook" 0
done

echo "----"
echo "pass=$pass fail=$fail"
if ((fail > 0)); then
  exit 1
fi
exit 0
