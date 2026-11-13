#!/bin/bash
# Regression test for the path-helper generator (cli/gen-route-helpers.sh;
# `snails new` stamps its call into a project's bin/test). The generator
# reads config/routes.rb through the pinned spinel's AST and emits literal
# helpers; a row it reads wrongly would emit a helper that looks fine and
# answers with the wrong path, so the row grammar, the name derivation (the
# runtime's rule) and the refusal paths are pinned here.
#
# Usage: bash scripts/test-gen-route-helpers.sh
# Exit: 0=all cases pass, 1=failure.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
G="$ROOT/cli/gen-route-helpers.sh"
SCAFFOLD_NEW="$ROOT/scaffold/new/config/routes.rb"
SCAFFOLD_FULL="$ROOT/scaffold/full/config/routes.rb"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK" || exit 1

# The parser is the pinned spinel (`spinel --dump-ast`): one pins file at the
# work root serves every case app, and the toolchain resolver materializes
# that rev from the cache or PATH once.
spinel_rev="$(awk -F'"' '/^SPINEL_REV=/ { print $2 }' "$ROOT/pins.toml")"
if [[ ! $spinel_rev =~ ^[0-9a-f]{4,40}$ ]]; then
  echo "cannot read SPINEL_REV from $ROOT/pins.toml" >&2
  exit 1
fi
printf 'SPINEL_REV="%s"\n' "$spinel_rev" >"$WORK/pins.toml"

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
  # mk_app <dir> <routes file> — an app tree with a route table, gen/, and
  # the database configuration the shared resolver marks an app root by.
  rm -rf "$1"
  mkdir -p "$1/config" "$1/gen"
  cp "$2" "$1/config/routes.rb"
  printf 'require_relative "../snails-core/database/sqlite"\n' > "$1/config/database.rb"
}

# The table shape the scaffold ships and the app-side helpers follow.
cat > routes-canonical.rb <<'RB'
# comment line the generator must skip
module Snails
  module RouteTable
    def self.get(path, controller, action = :index)
      ActionDispatch::Router::Route.new("GET", path, controller, action)
    end

    def self.post(path, controller, action = :create)
      ActionDispatch::Router::Route.new("POST", path, controller, action)
    end

    def self.table
      [
        ActionDispatch::Router::Route.new("GET", "/", Api::VersionController, :show),
        ActionDispatch::Router::Route.new("GET", "/up", Snails::HealthController, :show),
        post("/login", Api::LoginController),
        get("/servers", Api::ServersController),
        ActionDispatch::Router::Route.new("GET", "/devices/:id", Api::DevicesController, :show)
      ]
    end
  end
end
RB

# 1. A scaffolded project is fresh out of the generator.
mk_app app "$SCAFFOLD_NEW"
bash "$G" app >/dev/null 2>&1
chk "scaffold routes generate" $? 0
bash "$G" app --check >/dev/null 2>&1
chk "scaffold routes are fresh" $? 0
(cd app && bash "$G" --check) >/dev/null 2>&1
chk "app_root is optional from the app root" $? 0
grep -q 'def self.up_path' app/gen/route_helpers.rb
chk "the scaffold route derives its name from the path" $? 0
grep -q '    "/up"' app/gen/route_helpers.rb
chk "static path is a literal" $? 0

# 2. Content-gated write: a second run does not touch the file.
before="$(stat -c %Y app/gen/route_helpers.rb 2>/dev/null || stat -f %m app/gen/route_helpers.rb)"
sleep 1
bash "$G" app >/dev/null 2>&1
after="$(stat -c %Y app/gen/route_helpers.rb 2>/dev/null || stat -f %m app/gen/route_helpers.rb)"
chk "identical run leaves the file untouched" "$before" "$after"

# 3. The canonical forms: Route.new, verb helpers (default action from
#    the app's own definition), and the derived name for a pattern with
#    no static segment.
mk_app forms routes-canonical.rb
bash "$G" forms >/dev/null 2>&1
chk "canonical forms generate" $? 0
grep -q 'def self.version_show_path' forms/gen/route_helpers.rb
chk "dynamic-free pattern falls back to controller_action" $? 0
grep -q 'def self.up_path' forms/gen/route_helpers.rb
chk "a static path names itself" $? 0
grep -q 'def self.login_path' forms/gen/route_helpers.rb
chk "verb helper takes its default action" $? 0
grep -q 'def self.devices_path(id)' forms/gen/route_helpers.rb
chk "a dynamic path derives from its static segments" $? 0
grep -q '"/devices/" + id.to_s' forms/gen/route_helpers.rb
chk "dynamic pattern becomes a param expression" $? 0

# 3b. The core seed: an app file with NO helper definitions still parses
#     bare helper rows — the verb and default action come from core's
#     route_dsl, so `get("/", ...)` names itself after the seed default.
cat > seed-only.rb <<'RB'
module Snails
  module RouteTable
    def self.table
      [
        post("/login", Api::LoginController),
        get("/", Api::VersionController)
      ]
    end
  end
end
RB
mk_app seed seed-only.rb
bash "$G" seed >/dev/null 2>&1
chk "a helper-less table parses from the core seed" $? 0
grep -q 'def self.login_path' seed/gen/route_helpers.rb
chk "the seed reads a post row" $? 0
grep -q 'def self.version_index_path' seed/gen/route_helpers.rb
chk "the seed default action names the fallback row" $? 0

# 3c. A local definition overrides the seed — its own default action
#     wins over core's, so the derived name follows the local def.
cat > seed-override.rb <<'RB'
module Snails
  module RouteTable
    def self.get(path, controller, action = :show)
      ActionDispatch::Router::Route.new("GET", path, controller, action)
    end

    def self.table
      [
        get("/", Api::VersionController)
      ]
    end
  end
end
RB
mk_app override seed-override.rb
bash "$G" override >/dev/null 2>&1
chk "a local helper definition overrides the seed" $? 0
grep -q 'def self.version_show_path' override/gen/route_helpers.rb
chk "the local default action wins over the seed's" $? 0
grep -q 'def self.version_index_path' override/gen/route_helpers.rb 2>/dev/null
chk "the seed default no longer applies" $? 1

# 4. resources — five rows, collection/member names, only:, as:.
mk_app res "$SCAFFOLD_FULL"
bash "$G" res >/dev/null 2>&1
chk "resources expand" $? 0
grep -q 'def self.posts_path$' res/gen/route_helpers.rb
chk "collection name is the last static segment" $? 0
grep -q 'def self.post_path(id)' res/gen/route_helpers.rb
chk "member name is the naive singular" $? 0
grep -q 'def self.comment_path(post_id, id)' res/gen/route_helpers.rb
chk "nested member keeps both params" $? 0

# 4b. The flat-array form: rows in one array literal — each row line ends
#     with a comma, and a `resources` expansion is splatted in with `*`.
cat > res-flat.rb <<'RB'
module Snails
  module RouteTable
    def self.table
      [
        get("/up", Snails::HealthController, :show),
        *resources("/posts", Api::PostsController, :json),
        *resources("/posts/:post_id/comments", Api::CommentsController, :json)
      ]
    end
  end
end
RB
mk_app resflat res-flat.rb
bash "$G" resflat >/dev/null 2>&1
chk "the flat-array form generates" $? 0
grep -q 'def self.up_path$' resflat/gen/route_helpers.rb
chk "the flat-array form reads the plain row" $? 0
grep -q 'def self.post_path(id)' resflat/gen/route_helpers.rb
chk "the flat-array form splats the resource rows" $? 0
grep -q 'def self.comment_path(post_id, id)' resflat/gen/route_helpers.rb
chk "the flat-array form reads the nested resource" $? 0
cat > res-only.rb <<'RB'
module Snails
  module RouteTable
    def self.table
      [
        resources("/replies", Api::RepliesController, :json, [:index, :show])
      ]
    end
  end
end
RB
mk_app res2 res-only.rb
bash "$G" res2 >/dev/null 2>&1
chk "only: subset generates" $? 0
grep -q 'def self.replies_path$' res2/gen/route_helpers.rb
chk "only: keeps the listed collection action" $? 0
grep -q 'def self.reply_path(id)' res2/gen/route_helpers.rb
chk "ies singularizes to y" $? 0
grep -q 'def self.create_path' res2/gen/route_helpers.rb 2>/dev/null
chk "only: drops the unlisted actions" $? 1
cat > res-extra.rb <<'RB'
module Snails
  module RouteTable
    def self.table
      [
        resources("/stories", Api::StoriesController, :json, nil, :articles)
      ]
    end
  end
end
RB
mk_app res3 res-extra.rb
bash "$G" res3 >/dev/null 2>&1
chk "a resources argument the runtime cannot take is refused" $? 2

# 5. Collisions — one name, two patterns — are refused; a repeated
#    (name, pattern) pair is one helper, not a collision.
cat > collide.rb <<'RB'
module Snails
  module RouteTable
    def self.table
      [
        ActionDispatch::Router::Route.new("POST", "/devices", Api::DevicesController, :create),
        ActionDispatch::Router::Route.new("GET", "/devices/:id", Api::DevicesController, :show)
      ]
    end
  end
end
RB
mk_app collide collide.rb
out="$(bash "$G" collide 2>&1)"
chk "colliding names are refused" $? 2
[[ $out == *"config/routes.rb: devices is derived from more than one pattern"* ]]
chk "the collision names the routes" $? 0
[[ $out == *'two routes derive the same helper name — add `# as: <name>` to one of them'* ]]
chk "the collision message names the marker" $? 0
cat > same.rb <<'RB'
module Snails
  module RouteTable
    def self.table
      [
        ActionDispatch::Router::Route.new("POST", "/account/password", Api::PasswordsController, :create),
        ActionDispatch::Router::Route.new("PUT", "/account/password", Api::PasswordsController, :update)
      ]
    end
  end
end
RB
mk_app same same.rb
bash "$G" same >/dev/null 2>&1
chk "the same pattern under one name is one helper" $? 0
chk "one helper is emitted for it" "$(grep -c 'def self.account_password_path' same/gen/route_helpers.rb)" 1

# 5b. The build-time name marker: a row can carry `# as: <name>` (the
#     runtime ignores comments), which is how a colliding pair is named.
cat > marker.rb <<'RB'
module Snails
  module RouteTable
    def self.table
      [
        ActionDispatch::Router::Route.new("POST", "/devices", Api::DevicesController, :create),
        ActionDispatch::Router::Route.new("GET", "/devices/:id", Api::DevicesController, :show)  # as: device
      ]
    end
  end
end
RB
mk_app marker marker.rb
bash "$G" marker >/dev/null 2>&1
chk "a marked row generates" $? 0
grep -q 'def self.device_path(id)' marker/gen/route_helpers.rb
chk "the marker names the row" $? 0
grep -q 'def self.devices_path$' marker/gen/route_helpers.rb
chk "the unmarked row keeps its derived name" $? 0
cat > marker-res.rb <<'RB'
module Snails
  module RouteTable
    def self.table
      [
        resources("/posts", Api::PostsController, :json)  # as: articles
      ]
    end
  end
end
RB
mk_app marker-res marker-res.rb
bash "$G" marker-res >/dev/null 2>&1
chk "a marker on a resources row is refused (five rows, one name)" $? 2

# 5c. Ruby is read by the pinned spinel's parser: a row may span lines, a
#     local helper may branch, and a row whose arguments are not literals is
#     refused instead of guessed.
cat > multiline.rb <<'RB'
module Snails
  module RouteTable
    def self.table
      [
        get(
          "/multi/line",
          Api::LinesController
        )
      ]
    end
  end
end
RB
mk_app multiline multiline.rb
bash "$G" multiline >/dev/null 2>&1
chk "a multi-line row generates" $? 0
grep -q 'def self.multi_line_path' multiline/gen/route_helpers.rb
chk "the multi-line row derives its name" $? 0

cat > branched.rb <<'RB'
module Snails
  module RouteTable
    def self.fetch(path, controller, action = :show)
      if path.nil?
        raise "no path"
      end
      ActionDispatch::Router::Route.new("GET", path, controller, action)
    end

    def self.table
      [
        fetch("/", Api::BranchedController)
      ]
    end
  end
end
RB
mk_app branched branched.rb
bash "$G" branched >/dev/null 2>&1
chk "a helper with a nested block is learned" $? 0
grep -q 'def self.branched_show_path' branched/gen/route_helpers.rb
chk "the learned verb and default action reach the helper" $? 0

cat > dynamic.rb <<'RB'
module Snails
  module RouteTable
    def self.table
      [
        get("/variable/#{ENV["X"]}", Api::VarController)
      ]
    end
  end
end
RB
mk_app dynamicrow dynamic.rb
out="$(bash "$G" dynamicrow 2>&1)"
chk "an interpolated path is refused" $? 2
if [[ $out == *"must be a literal string"* ]]; then match=0; else match=1; fi
chk "the refusal names the literal contract" "$match" 0

cat > hashpath.rb <<'RB'
module Snails
  module RouteTable
    def self.table
      [
        get("/collections/items#section", Api::ItemsController)
      ]
    end
  end
end
RB
mk_app hashpath hashpath.rb
out="$(bash "$G" hashpath 2>&1)"
chk "a path that cannot name a helper is refused" $? 2
if [[ $out == *"cannot derive a helper name"* ]]; then match=0; else match=1; fi
chk "the refusal points at the marker" "$match" 0

# 6. Refusals: an unreadable row, a missing table, a missing gen/.
cat > unknown.rb <<'RB'
module Snails
  module RouteTable
    def self.table
      [
        mystery("/x", Api::XController)
      ]
    end
  end
end
RB
mk_app unknown unknown.rb
out="$(bash "$G" unknown 2>&1)"
chk "an unreadable row stops the generator" $? 2
if [[ $out == *"unknown helper"* ]]; then match=0; else match=1; fi
chk "the refusal says why" "$match" 0
rm -rf noget; mkdir -p noget/config
cp routes-canonical.rb noget/config/routes.rb
bash "$G" noget >/dev/null 2>&1
chk "a missing gen/ is a structural error" $? 2
mkdir -p notable/config notables/gen
printf 'module Snails\n  module RouteTable\n  end\nend\n' > notable/config/routes.rb
bash "$G" notable >/dev/null 2>&1
chk "an empty table is a structural error" $? 2

# 7. --check: stale and missing outputs exit 1.
mk_app check routes-canonical.rb
bash "$G" check --check >/dev/null 2>&1
chk "--check without an output is stale" $? 1
bash "$G" check >/dev/null 2>&1
bash "$G" check --check >/dev/null 2>&1
chk "--check after a run is fresh" $? 0
printf '\n# drift\n' >> check/gen/route_helpers.rb
bash "$G" check --check > stale-msg.out 2>&1
chk "an edited output is stale" $? 1
grep -q "run: snails gen-route-helpers check" stale-msg.out
chk "the stale report names the CLI repair" $? 0

# 8. Interpreter contract: the generator never calls ruby.
NORUBY="$WORK/noruby"
mkdir -p "$NORUBY"
cat > "$NORUBY/ruby" <<'SH'
#!/bin/bash
echo "ruby must not be called by the CLI engines" >&2
exit 127
SH
chmod +x "$NORUBY/ruby"
mk_app noruby routes-canonical.rb
PATH="$NORUBY:$PATH" bash "$G" noruby >/dev/null 2>&1
chk "generates without ruby" $? 0

echo
if ((fail)); then
  echo "FAILED: $fail (passed: $pass)"
  exit 1
fi
echo "all $pass cases pass"
