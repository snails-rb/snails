#!/bin/bash
# Regression test for the require-all generator (cli/gen-require-all.sh;
# the app tree carries no copy — bin/snails runs it from cli/). The
# generator turns
# each gen/* `# scan:` spec into the literal require list spinel's AOT
# require graph needs — a file the scan misses drops out of the graph
# silently, so the scan semantics (recursion, order, dedupe, exclusion)
# and the marker contract are pinned here.
#
# Usage: bash scripts/test-gen-require-all.sh
# Exit: 0=all cases pass, 1=failure.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
G="$ROOT/cli/gen-require-all.sh"
SEED="$ROOT/scaffold/seed/gen"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK" || exit 1

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

mk_app() {
  # A fresh project's app/: the seed gen files over an empty
  # app/controllers. The database configuration makes the tree an app root for the
  # shared resolver.
  rm -rf "$1"
  mkdir -p "$1/app/controllers" "$1/gen" "$1/config"
  cp "$SEED"/*.rb "$1/gen/"
  printf 'require_relative "../snails-core/database/sqlite"\n' > "$1/config/database.rb"
}

region() {
  # region <gen file> <scan spec...> — write a spec-only region.
  local file="$1"
  shift
  {
    echo "# generated region test"
    echo "# >>> snails generate"
    local scan
    for scan in "$@"; do
      echo "# scan: $scan"
    done
    echo "# <<< snails generate"
  } > "$file"
}

# 1. The seed is in agreement with its own scan: a fresh project is fresh.
mk_app app
bash "$G" app --check >/dev/null 2>&1
chk "seed app is fresh" $? 0

# 1b. <app_root> is optional: the shared resolver fills it in (nearest adapter
# entry at or above $PWD), announced only when it leaves $PWD.
(cd app && bash "$G" --check) >/dev/null 2>&1
chk "app_root is optional from the app root" $? 0
(cd app/gen && bash "$G" --check) >/dev/null 2>resolve.err
chk "a subdirectory resolves up to the app root" $? 0
grep -q '\[snails\] app root ' resolve.err
chk "the generator announces the resolved root" $? 0

# 2. Regeneration writes only what changed (content-gated): the no-op run
#    leaves the mtime alone, so the bundle cache boundary holds.
touch -t 200001010000 app/gen/controllers.rb
touch stamp
bash "$G" app >/dev/null 2>&1
chk "no-op regeneration exits 0" $? 0
if [[ -z "$(find app/gen/controllers.rb -newer stamp)" ]]; then stat_code=0; else stat_code=1; fi
chk "no-op regeneration leaves the mtime" "$stat_code" 0

# 3. A new controller lands in the generated block; --check then passes.
cat > app/app/controllers/ping_controller.rb <<'RB'
class PingController
end
RB
bash "$G" app --check > stale-check.out 2>&1
chk "a new file makes --check stale" $? 1
grep -q "run: snails gen-require-all app" stale-check.out
chk "the stale report names the CLI repair" $? 0
if grep -q 'stale: ' stale-check.out; then gra_list=1; else gra_list=0; fi
chk "the default report hides the file list" "$gra_list" 0
bash "$G" app --check --verbose > stale-verbose.out 2>&1
chk "verbose check still exits 1" $? 1
grep -q 'stale: gen/controllers.rb' stale-verbose.out
chk "--verbose lists the stale file" $? 0
bash "$G" app --verbose >/dev/null 2>&1
chk "--verbose without --check is an error" $? 2
bash "$G" app >/dev/null 2>&1
chk "regeneration writes the require" $? 0
grep -q '^require_relative "../app/controllers/ping_controller"$' app/gen/controllers.rb
chk "the new require is listed" $? 0
bash "$G" app --check >/dev/null 2>&1
chk "fresh after regeneration" $? 0

# 3b. app/lib is scanned by the seed default (`lib/**/*`): a new file — even
#     nested — is picked up without the app editing gen/lib.rb.
mkdir -p app/app/lib/reporting/deep
printf 'module Reporting\nend\n' > app/app/lib/reporting/deep/format.rb
bash "$G" app --check >/dev/null 2>&1
chk "an app/lib file makes --check stale" $? 1
bash "$G" app >/dev/null 2>&1
chk "the lib seed default regenerates" $? 0
grep -q '^require_relative "../app/lib/reporting/deep/format"$' app/gen/lib.rb
chk "a nested app/lib file is required" $? 0
bash "$G" app --check >/dev/null 2>&1
chk "app/lib is fresh after regeneration" $? 0

# 3c. app/forms is scanned recursively by the seed default (`forms/**/*`):
#     a form lands without the app editing gen/forms.rb, even in a subfolder.
mkdir -p app/app/forms/admin
printf 'class SignupForm < Snails::Form\nend\n' > app/app/forms/signup_form.rb
printf 'class Admin::SignupForm < Snails::Form\nend\n' > app/app/forms/admin/signup_form.rb
bash "$G" app --check >/dev/null 2>&1
chk "an app/forms file makes --check stale" $? 1
bash "$G" app >/dev/null 2>&1
chk "the forms seed default regenerates" $? 0
grep -q '^require_relative "../app/forms/signup_form"$' app/gen/forms.rb &&
  grep -q '^require_relative "../app/forms/admin/signup_form"$' app/gen/forms.rb
chk "a form and a namespaced form are required" $? 0
bash "$G" app --check >/dev/null 2>&1
chk "app/forms is fresh after regeneration" $? 0

# 3d. Every seed group scans recursively: dropping a file into the folder or a
#     subfolder loads it without editing gen/*. Models, forms, helpers, jobs,
#     mailers, and services use `group/**/*`; controllers put concerns first.
mk_app groups
mkdir -p groups/app/models/billing groups/app/helpers/admin groups/app/jobs/admin groups/app/mailers/admin groups/app/services/admin
printf 'class User < Sqlx::Base; end\n' > groups/app/models/user.rb
printf 'class Billing::Invoice < Sqlx::Base; end\n' > groups/app/models/billing/invoice.rb
printf 'module MoneyHelper; end\n' > groups/app/helpers/admin/money_helper.rb
printf 'class WelcomeJob < ActiveJob::Base; end\n' > groups/app/jobs/admin/welcome_job.rb
printf 'class UserMailer < ApplicationMailer; end\n' > groups/app/mailers/admin/user_mailer.rb
printf 'class Signup; end\n' > groups/app/services/admin/signup.rb
bash "$G" groups --check >/dev/null 2>&1
chk "a file in any seed group makes --check stale" $? 1
bash "$G" groups >/dev/null 2>&1
chk "the seed defaults regenerate" $? 0
grep -q '^require_relative "../app/models/user"$' groups/gen/models.rb &&
  grep -q '^require_relative "../app/models/billing/invoice"$' groups/gen/models.rb
chk "the models seed default loads a model and a namespaced model" $? 0
grep -q '^require_relative "../app/helpers/admin/money_helper"$' groups/gen/helpers.rb
chk "the helpers seed default loads a nested file" $? 0
grep -q '^require_relative "../app/jobs/admin/welcome_job"$' groups/gen/jobs.rb
chk "the jobs seed default loads a nested file" $? 0
grep -q '^require_relative "../app/mailers/admin/user_mailer"$' groups/gen/mailers.rb
chk "the mailers seed default loads a nested file" $? 0
grep -q '^require_relative "../app/services/admin/signup"$' groups/gen/services.rb
chk "the services seed default loads a nested file" $? 0
bash "$G" groups --check >/dev/null 2>&1
chk "every seed group is fresh after regeneration" $? 0

# 3e. The app's boot is the authority for the required groups: a tree pinned
#     before the lib group existed (boot without gen/lib) generates without
#     gen/lib.rb — a newer CLI must not demand a file its boot does not load.
#     A boot that does require it fails loudly when the file is gone.
mk_app skew
cat > skew/boot.rb <<'RB'
require_relative "gen/controllers"
require_relative "gen/helpers"
require_relative "gen/mailers"
require_relative "gen/models"
require_relative "gen/jobs"
require_relative "gen/services"
require_relative "gen/route_helpers"
RB
rm skew/gen/lib.rb
bash "$G" skew --check >/dev/null 2>&1
chk "a boot without gen/lib does not demand it" $? 0

mk_app skew2
cat > skew2/boot.rb <<'RB'
require_relative "gen/lib"
require_relative "gen/controllers"
RB
rm skew2/gen/lib.rb
bash "$G" skew2 >/dev/null 2>&1
chk "a boot that requires gen/lib fails without it" $? 2

# 3f. The vendored core boot is the authority over a legacy app boot: an
#     older app boot naming fewer groups must not narrow the core chain.
mk_app coreboot
cat > coreboot/boot.rb <<'RB'
require_relative "gen/controllers"
RB
mkdir -p coreboot/snails-core
cp "$ROOT/runtime/boot.rb" coreboot/snails-core/boot.rb
rm coreboot/gen/lib.rb
bash "$G" coreboot >/dev/null 2>&1
chk "the core boot is the authority over a legacy app boot" $? 2

# 4. Recursion: a trailing `**` is one level, `**/*` recurses. Hidden
#    entries are not matched (the scan is explicit about its files).
mk_app rec
mkdir -p rec/app/models/concerns rec/app/models/deep/nested rec/app/models/.hidden
printf 'class A; end\n' > rec/app/models/top.rb
printf 'class B; end\n' > rec/app/models/concerns/mixin.rb
printf 'class C; end\n' > rec/app/models/deep/nested/deep.rb
printf 'class D; end\n' > rec/app/models/.hidden/skipped.rb
region rec/gen/models.rb 'models/**'
bash "$G" rec >/dev/null 2>&1
grep -q 'require_relative "../app/models/top"' rec/gen/models.rb
chk "trailing ** lists direct children" $? 0
if grep -q 'models/concerns/mixin' rec/gen/models.rb; then chk "trailing ** stops at one level" 1 0; else chk "trailing ** stops at one level" 0 0; fi
if grep -q 'deep/nested/deep' rec/gen/models.rb; then chk "trailing ** does not recurse" 1 0; else chk "trailing ** does not recurse" 0 0; fi
if grep -q '.hidden' rec/gen/models.rb; then chk "hidden entries are excluded" 1 0; else chk "hidden entries are excluded" 0 0; fi
printf 'module K; end\n' > rec/app/models/.dotfile.rb
region rec/gen/models.rb 'models/.d*'
bash "$G" rec >/dev/null 2>&1
grep -q '^require_relative "../app/models/.dotfile"$' rec/gen/models.rb
chk "a dot-leading component matches hidden files" $? 0

region rec/gen/models.rb 'models/**/*'
bash "$G" rec >/dev/null 2>&1
grep -q 'require_relative "../app/models/deep/nested/deep"' rec/gen/models.rb
chk "**/* recurses" $? 0

# 5. Spec order is load order, and the first pattern to match a file wins
#    (a file covered twice is required once).
mk_app order
mkdir -p order/app/models/concerns
printf 'class M; end\n' > order/app/models/concerns/a.rb
printf 'class N; end\n' > order/app/models/b.rb
region order/gen/models.rb 'models/concerns/**' 'models/**'
bash "$G" order >/dev/null 2>&1
expected="$(printf '%s\n' \
  '# generated region test' \
  '# >>> snails generate' \
  '# scan: models/concerns/**' \
  '# scan: models/**' \
  'require_relative "../app/models/concerns/a"' \
  'require_relative "../app/models/b"' \
  '# <<< snails generate')"
if [[ "$(cat order/gen/models.rb)" == "$expected" ]]; then order_code=0; else order_code=1; fi
chk "scan order + first-match dedupe" "$order_code" 0

# 6. Wildcards: `?` and `[]` match within one component.
mk_app wild
mkdir -p wild/app/helpers
printf 'module H; end\n' > wild/app/helpers/ab.rb
printf 'module I; end\n' > wild/app/helpers/ac.rb
printf 'module J; end\n' > wild/app/helpers/zz.rb
region wild/gen/helpers.rb 'helpers/[a]?.rb'
bash "$G" wild >/dev/null 2>&1
grep -q 'helpers/ab' wild/gen/helpers.rb && grep -q 'helpers/ac' wild/gen/helpers.rb
chk "bracket + question wildcards match" $? 0
if grep -q 'helpers/zz' wild/gen/helpers.rb; then chk "wildcards do not overmatch" 1 0; else chk "wildcards do not overmatch" 0 0; fi

# 7. A literal directory that matches nothing is probably a typo: warn.
mk_app warn
mkdir -p warn/app/helpers/emptydir
region warn/gen/helpers.rb 'helpers/emptydir/**'
out="$(bash "$G" warn 2>&1)"; code=$?
chk "empty literal dir still exits 0" "$code" 0
grep -q 'scan matched nothing: helpers/emptydir/\*\*' <<<"$out"
chk "empty literal dir warns" $? 0

# 8. Marker contract: damaged markers and hand edits are structural errors.
mk_app damage
region damage/gen/jobs.rb
printf '# <<< snails generate\n' >> damage/gen/jobs.rb
bash "$G" damage >/dev/null 2>&1
chk "double end marker fails" $? 2

mk_app damage
region damage/gen/jobs.rb
sed -i '$d' damage/gen/jobs.rb
bash "$G" damage >/dev/null 2>&1
chk "unclosed marker fails" $? 2

mk_app damage
echo '# jobs — out of the generator' > damage/gen/jobs.rb
bash "$G" damage >/dev/null 2>&1
chk "a core file without a region fails" $? 2

mk_app damage
region damage/gen/jobs.rb 'jobs/**'
sed -i '3i # a hand edit inside the region' damage/gen/jobs.rb
bash "$G" damage >/dev/null 2>&1
chk "a hand edit in the region fails" $? 2

mk_app damage
cat > damage/gen/extra.rb <<'RB'
# an app-owned extra group with no region is left alone
RB
bash "$G" damage --check >/dev/null 2>&1
chk "a non-core file without a region is skipped" $? 0

# 9. A non-core file with a region is processed like any other.
mk_app extra
mkdir -p extra/app/services
printf 'class S; end\n' > extra/app/services/s_service.rb
region extra/gen/extra.rb 'services/**'
bash "$G" extra >/dev/null 2>&1
chk "a non-core file with a region is generated" $? 0
grep -q '^require_relative "../app/services/s_service"$' extra/gen/extra.rb
chk "the extra group require is listed" $? 0

# 10. Structural argument errors.
bash "$G" >/dev/null 2>&1
chk "no arguments fails" $? 2
bash "$G" --check >/dev/null 2>&1
chk "no app_root fails" $? 2
bash "$G" app nope >/dev/null 2>&1
chk "an extra argument fails" $? 2
bash "$G" nope-dir >/dev/null 2>&1
chk "a missing app_root fails" $? 2
mk_app damage && rm -rf damage/app
bash "$G" damage >/dev/null 2>&1
chk "a missing app/ fails" $? 2
mk_app damage && rm -rf damage/gen
bash "$G" damage >/dev/null 2>&1
chk "a missing gen/ fails" $? 2
mk_app damage && rm damage/gen/services.rb
bash "$G" damage >/dev/null 2>&1
chk "a missing core file fails" $? 2

# 11. Interpreter contract: the generator is shell-only. With a `ruby`
#     that fails loudly shadowed on PATH it still regenerates.
NORUBY="$WORK/noruby"
mkdir -p "$NORUBY"
cat > "$NORUBY/ruby" <<'SH'
#!/bin/bash
echo "ruby must not be called by the CLI engines" >&2
exit 127
SH
chmod +x "$NORUBY/ruby"
cat > app/app/controllers/slow_controller.rb <<'RB'
class SlowController
end
RB
PATH="$NORUBY:$PATH" bash "$G" app >/dev/null 2>&1
chk "generation runs without ruby" $? 0
grep -q 'slow_controller' app/gen/controllers.rb
chk "the require landed without ruby" $? 0

echo "----"
echo "pass=$pass fail=$fail"
if ((fail > 0)); then
  exit 1
fi
exit 0
