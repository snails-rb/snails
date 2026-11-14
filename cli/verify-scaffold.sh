#!/bin/bash
# Scaffold contract — an app tree must satisfy the snails app contract
# (`GET /up`) without carrying framework files: the server entry
# (main.rb) is scaffold-owned byte-for-byte, the boot entry
# (snails-core/boot.rb) and its selected profile (snails-core/boot/*.rb) are
# core-owned, the profile selection (config/boot.rb) is app-owned, the
# health controller is core-owned (snails-core/), and the app declares only
# the route. The database configuration and require-all files are
# app-owned; the contract for them is that they exist.
#
# This script only compares and never writes, so drift surfaces here
# instead of being silently overwritten.
#
# Checks:
#   1. the server entry (main.rb) matches scaffold/main.rb byte-for-byte
#      — app Snails::Main overrides belong in config/environment.rb (the boot
#      chain's last require)
#   1b. no app-level boot.rb exists; the boot chain is core-owned at
#      snails-core/boot.rb and must be present in the vendored core. A
#      harness target boot that still requires the retired app boot is
#      named too.
#   2. the core-default require-all files, config/application.rb,
#      config/environment.rb, and the app's database configuration
#      (config/database.rb) exist — the core boot chain requires them;
#      config/database.rb requires exactly one backend. A stray retired name
#      (config/db.rb) is an error. Their content is app-owned, so the
#      contract only requires that they exist.
#   3. the /up contract holds: config/routes.rb declares GET /up, and no
#      app file requires the health controller (the core boot loads its
#      definition — a stale require points at a deleted file)
#   4. Snails::HealthController is defined exactly once, in the vendored
#      core (snails-core/snails/health_controller.rb); an app/** definition is
#      the retired scaffold copy and must be deleted
#
# usage: snails verify-scaffold <app_root>
#
# exit: 0 = contract satisfied, 1 = violation (missing or drifted canonical,
#       missing require-all/config file, broken /up contract, stray health
#       definition), 2 = structural error (usage, unreadable tree).
set -euo pipefail

ENGINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$ENGINE_DIR/.." && pwd)"
# shellcheck source=app-root.sh
source "$ENGINE_DIR/app-root.sh"
# shellcheck source=vendor-dir.sh
source "$ENGINE_DIR/vendor-dir.sh"
MAIN_CANONICAL="$ROOT/scaffold/main.rb"
CORE_HEALTH_RB="$SNAILS_VENDOR_DIR/snails/health_controller.rb"
# The core boot chain's require-all files — one file per folder group.
# Each app's file lists its own classes, so the contract only requires that
# the file exists; content stays app-owned.
REQUIRED_APP_FILES=(gen/lib.rb gen/controllers.rb gen/helpers.rb gen/mailers.rb gen/models.rb gen/model_columns.rb gen/forms.rb gen/jobs.rb gen/services.rb gen/route_helpers.rb)
# The definition the core runtime owns: a class statement whose name is
# exactly `HealthController` (word boundaries, so `HealthControllerFoo` is
# not one).
DEFINER_RE='(^|[^A-Za-z0-9_])class HealthController([^A-Za-z0-9_]|$)'

struct_fail() {
  echo "[snails] $*" >&2
  exit 2
}

# list_join <sep> <newline-separated list> — print the items joined by <sep>.
list_join() {
  local sep="$1" items="$2" out="" item
  while IFS= read -r item; do
    [[ -n $item ]] || continue
    if [[ -z $out ]]; then out="$item"; else out="$out$sep$item"; fi
  done <<<"$items"
  printf '%s' "$out"
}

# definers <root> — print every <root>/**/*.rb file that defines
# Snails::HealthController, sorted for a stable report.
definers() {
  local root="$1" file
  [[ -d $root ]] || return 0
  while IFS= read -r file; do
    if grep -Eq "$DEFINER_RE" "$file"; then
      printf '%s\n' "$file"
    fi
  done < <(find "$root" -type f -name '*.rb' | LC_ALL=C sort)
}

if (($# != 1)) || [[ -z ${1:-} ]]; then
  struct_fail "usage: snails verify-scaffold <app_root>"
fi
app_root="$1"
while [[ $app_root == */ && $app_root != / ]]; do
  app_root="${app_root%/}"
done
[[ -d $app_root ]] || struct_fail "no such app root: $app_root — pass the directory that holds config/database.rb"
sync_arg="$(app_root_argument "$app_root")"
sync_command="snails sync"
[[ -n $sync_arg ]] && sync_command+=" $(shell_quote "$sync_arg")"
[[ -f $MAIN_CANONICAL ]] || struct_fail "the installed CLI is missing its scaffold entry template (scaffold/main.rb) — reinstall or upgrade snails"

errors=()

# 1. the server entry: scaffold-owned byte-for-byte. Drift here means app
#    code (or a re-copied core block) crept back into main.rb — the place
#    for it is config/environment.rb, which the boot chain requires last.
main_rb="$app_root/main.rb"
if [[ ! -f $main_rb ]]; then
  errors+=("main.rb: missing (the scaffold-owned server entry)")
elif grep -q '^require_relative "boot"$' "$main_rb"; then
  errors+=("main.rb: requires the retired app boot — replace it with the current scaffold entry (require_relative \"$SNAILS_VENDOR_DIR/boot\" + Snails::Main.start)")
  diff -u --label "scaffold/main.rb" --label "app/main.rb" "$MAIN_CANONICAL" "$main_rb" || true
elif ! cmp -s "$main_rb" "$MAIN_CANONICAL"; then
  errors+=("main.rb: differs from the scaffold entry — app Snails::Main overrides belong in config/environment.rb (the boot chain's last require), not the entry")
  diff -u --label "scaffold/main.rb" --label "app/main.rb" "$MAIN_CANONICAL" "$main_rb" || true
fi

# 1b. the boot entry is core-owned: the app root carries no boot.rb, and
#     the vendored core carries snails-core/boot.rb. The boot entry selects
#     the app-owned config/boot.rb profile; its target profile file is
#     core-owned. A harness boot that still names the retired app boot is
#     a stale require (the file is gone).
boot_rb="$app_root/boot.rb"
if [[ -e $boot_rb ]]; then
  errors+=("boot.rb: retired — the boot entry is $SNAILS_VENDOR_DIR/boot.rb (vendored core); delete boot.rb after replacing main.rb with scaffold/main.rb")
fi
boot_entry="$app_root/$SNAILS_VENDOR_DIR/boot.rb"
if [[ ! -f $boot_entry ]]; then
  errors+=("$SNAILS_VENDOR_DIR/boot.rb: missing (the core boot entry) — run: $sync_command to vendor the core")
elif grep -q '^require_relative "\.\./config/boot"$' "$boot_entry"; then
  boot_profile="$app_root/config/boot.rb"
  if [[ ! -f $boot_profile ]]; then
    errors+=("config/boot.rb: missing — the boot entry requires it (run: $sync_command to seed)")
  else
    profile_re="^require_relative \"\\.\\./$SNAILS_VENDOR_DIR/boot/\\([A-Za-z0-9_]*\\)\"$"
    profile_targets="$(sed -n "s|$profile_re|\\1|p" "$boot_profile")"
    profile_count="$(printf '%s\n' "$profile_targets" | grep -c . || true)"
    if [[ $profile_count != 1 ]]; then
      errors+=("config/boot.rb: must select exactly one boot profile with require_relative \"../$SNAILS_VENDOR_DIR/boot/<profile>\"")
    elif [[ ! -f "$app_root/$SNAILS_VENDOR_DIR/boot/$profile_targets.rb" ]]; then
      errors+=("$SNAILS_VENDOR_DIR/boot/$profile_targets.rb: missing (the selected boot profile) — run: $sync_command to vendor the core")
    fi
  fi
fi
harness_boot="$app_root/harness/boot.rb"
if [[ -f $harness_boot ]] && grep -q '^require_relative "\.\./boot"$' "$harness_boot"; then
  errors+=("harness/boot.rb: requires the retired app boot — change it to require_relative \"../$SNAILS_VENDOR_DIR/boot\"")
fi

# 2. the core-default require-all files: the core boot chain requires them
#    all.
for rel in "${REQUIRED_APP_FILES[@]}"; do
  [[ -f "$app_root/$rel" ]] || errors+=("$rel: core-default require-all file missing — run: $sync_command to seed")
done

# the core boot chain also requires the app config reopen — sync seeds it
# once (values are app-owned).
[[ -f "$app_root/config/application.rb" ]] \
  || errors+=("config/application.rb: missing — the boot chain requires it (run: $sync_command to seed)")

# ...and the app environment, the boot chain's last require — same seed rule.
[[ -f "$app_root/config/environment.rb" ]] \
  || errors+=("config/environment.rb: missing — the boot chain requires it (run: $sync_command to seed)")

# 2b. the app's database configuration: the core boot chain requires
#     `config/database`, which requires exactly one adapter
#     (snails-core/database/sqlite or snails-core/database/postgresql). Which
#     backend, and any app comments, are app-owned, so the contract here is
#     that the file exists. Sync seeds a missing file once from the retired
#     DB= declaration (sqlite default) and migrates the retired name
#     (`config/db.rb`) in place, so an existing app is not broken by the
#     change. A stray retired file is a hard error: nothing reads it, but a
#     human would mistake it for the database configuration.
if [[ -f "$app_root/config/db.rb" ]]; then
  errors+=("config/db.rb: the retired configuration name — rename it to config/database.rb (run: $sync_command to migrate the anchored require line)")
fi
if [[ ! -f "$app_root/config/database.rb" ]]; then
  errors+=("config/database.rb: missing (the app's database configuration — the boot chain requires it; require exactly one of $SNAILS_VENDOR_DIR/database/sqlite or $SNAILS_VENDOR_DIR/database/postgresql, or rerun 'snails new' for the expected layout)")
fi

# 3. /up contract: routes declares GET /up, and no app-side file requires
#    the health controller. The core definition loads from the boot chain,
#    so a stale require is drift (the file it names is gone).
routes="$app_root/config/routes.rb"
for rel in gen/controllers.rb config/routes.rb; do
  f="$app_root/$rel"
  if [[ -f $f ]] && grep -Eq 'require.*snails/health_controller' "$f"; then
    errors+=("$rel: requires the retired health controller — the core loads it; delete the require (for gen/controllers.rb rerun the require-all generator)")
  fi
done

if [[ -f $routes ]]; then
  # A GET /up row is written either as Route.new("GET", "/up", ...) or
  # through a verb helper: bare `get "/up"` or `get("/up", ...)`.
  if ! grep -Eq 'Route\.new\("GET",[[:space:]]*"/up"' "$routes" \
    && ! grep -Eq '(^|[^A-Za-z0-9_])get([[:space:]]+|\()"?/up"?' "$routes"; then
    errors+=("config/routes.rb declares no GET /up route — add: get \"/up\", Snails::HealthController, :show")
  fi
else
  errors+=("config/routes.rb missing — restore the route table (a scaffolded app declares GET /up)")
fi

# 4. one definition, core side: snails-core/snails/health_controller.rb
#    defines Snails::HealthController; an app/** definition is the retired
#    scaffold copy.
app_definers=()
while IFS= read -r file; do
  app_definers+=("${file#"$app_root"/}")
done < <(definers "$app_root/app")
if (( ${#app_definers[@]} != 0 )); then
  errors+=("app/** must not define Snails::HealthController ($(list_join ', ' "$(printf '%s\n' "${app_definers[@]}")")) — the core provides it; delete the retired scaffold copy and rerun: $sync_command")
fi

core_definers=()
while IFS= read -r file; do
  core_definers+=("${file#"$app_root"/}")
done < <(definers "$app_root/$SNAILS_VENDOR_DIR")
found_core="$(list_join ', ' "$(printf '%s\n' ${core_definers[@]+"${core_definers[@]}"})")"
[[ -n $found_core ]] || found_core="none"
if (( ${#core_definers[@]} != 1 )) || [[ ${core_definers[0]:-} != "$CORE_HEALTH_RB" ]]; then
  errors+=("$SNAILS_VENDOR_DIR/** must define Snails::HealthController exactly once at $CORE_HEALTH_RB (found: $found_core) — run: $sync_command to vendor the core")
fi

if (( ${#errors[@]} == 0 )); then
  echo "[snails] $app_root satisfies the scaffold contract"
  exit 0
fi

echo "[snails] $app_root violates the scaffold contract:" >&2
for e in ${errors[@]+"${errors[@]}"}; do
  echo "  - $e" >&2
done
exit 1
