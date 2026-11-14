#!/bin/bash
# Generate literal path helpers from an app's route table.
#
# Why generate: a path string must have a single source — the route
# declaration. A hand-written helper module drifts from it, and a runtime
# lookup over the table returns the wrong path whenever two patterns derive
# the same name (a collection and its member, say). Generated helpers
# are literals: a caller never pays for a lookup, and a name can never quietly
# point at another route.
#
# What it reads: config/routes.rb, parsed by the pinned spinel
# (`spinel --dump-ast`) — the same parser the app compiles with. The table is
# the literal array returned by `def self.table`; its elements are verb-helper
# calls, `Route.new` calls, and `resources` calls (bare or splatted). A row is
# a declaration, so it may be formatted freely across lines; a row whose
# arguments are not literals (a variable, a computed path, a loop) is refused,
# because the helper would have to guess.
#
# Local helper definitions (`def self.posted(path, controller, action =
# :create)`) are learned from their parameters and the `Route.new` in their
# body — a conditional inside the body no longer hides the verb. The four core
# verb helpers and their default actions are the seed (runtime/snails/
# route_dsl.rb); a local definition replaces the same-name seed entry.
#
# Names: the generator's own derivation — the pattern's static segments
# joined by "_", falling back to controller/action when the pattern has
# none. `resources` names its collection after the last static segment and
# its member after the naive singular. A row that needs a different name
# carries the build-time marker `# as: <name>` (the same pattern as the
# generated lines in the load-list region): the runtime ignores comments, so
# the marker adds nothing to the runtime surface. The marker belongs to the
# row that starts on that line. A derived name that is not a Ruby identifier
# (say, a path with a `#` in it) is refused rather than emitted.
#
# Collisions: two rows deriving the same name from *different* patterns
# are refused. One of them would have to win, and a helper that quietly
# returns the other row's path is the failure this generator exists to
# prevent. Give one row the `# as: <name>` marker.
#
# Content-gated write: an identical result leaves the file untouched (the
# app's test runner decides its cache from source mtimes).
#
# Usage:
#   bash cli/gen-route-helpers.sh [<app_root>]          regenerate (writes only on change)
#   bash cli/gen-route-helpers.sh [<app_root>] --check  freshness check only
#   <app_root> omitted resolves through cli/app-root.sh (nearest app root
#   at or above $PWD; outside the app, pass it).
#
# Exit: 0 = in sync · 1 = stale (--check) · 2 = structural error (usage, unreadable row, collision)
set -euo pipefail

# App-root resolution is shared with the CLI and the other engines.
GEN_SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=app-root.sh
source "$GEN_SCRIPTS/app-root.sh"

die() {
  local code="$1"
  shift
  echo "[snails] $*" >&2
  exit "$code"
}

# --- the route table's verb helpers -----------------------------------------
#
# The four verb helpers belong to core (`runtime/snails/route_dsl.rb`): an app
# declares rows with a bare `post("/login", Api::LoginController)` and never
# defines the helpers itself. CORE_HELPERS below mirrors that core
# definition — the HTTP verb and the RESTful default action per helper —
# so a row parses even in an app file that declares no helpers at all.
#
# An app that still declares `def self.x(...)` locally overrides the seed:
# its own definition replaces the same-name entry, so a local verb or
# default is read, not misread. A helper outside the seed and the local
# definitions stays unknown — its row stops the generator (exit 2).
#
# HELPERS holds "name|VERB|default-action" entries; bash 3.2 has no
# associative arrays.

CORE_HELPERS=" get|GET|index post|POST|create put|PUT|update delete|DELETE|destroy"
HELPERS="$CORE_HELPERS"

helper_field() {
  local entry rest
  for entry in $HELPERS; do
    [[ ${entry%%|*} == "$1" ]] || continue
    rest="${entry#*|}"
    if [[ $2 == verb ]]; then
      printf '%s' "${rest%%|*}"
    else
      printf '%s' "${rest##*|}"
    fi
    return 0
  done
  return 1
}

helper_known() {
  helper_field "$1" verb >/dev/null 2>&1
}

# A local definition replaces the same-name seed entry.
learn_helper() {
  local name="$1" verb="$2" default="$3" entry rest
  rest=""
  for entry in $HELPERS; do
    [[ ${entry%%|*} == "$name" ]] && continue
    rest="$rest $entry"
  done
  HELPERS="$rest $name|$verb|$default"
}

# --- name derivation (the runtime's rule) -----------------------------------

# derive_name <pattern> <controller> <action>
derive_name() {
  local pattern="$1" controller="$2" action="$3" seg base klass
  base=""
  local IFS=/
  local parts=($pattern)
  unset IFS
  for seg in ${parts[@]+"${parts[@]}"}; do
    [[ -n $seg && $seg != :* ]] || continue
    if [[ -z $base ]]; then
      base="$seg"
    else
      base="$base"_"$seg"
    fi
  done
  if [[ -n $base ]]; then
    printf '%s' "$base"
    return 0
  fi
  klass="${controller##*::}"
  klass="${klass%Controller}"
  klass="$(printf '%s' "$klass" | sed -E 's/([a-z0-9])([A-Z])/\1_\2/g' | tr '[:upper:]' '[:lower:]')"
  if [[ -z $klass ]]; then
    printf '%s' "$action"
  else
    printf '%s' "$klass"_"$action"
  fi
}

# singularize_name <name> — the runtime's naive singular for member rows.
singularize_name() {
  local s="$1"
  if [[ $s == *ies && ${#s} -gt 3 ]]; then
    printf '%s' "${s%ies}y"
  elif [[ $s == *s && ${#s} -gt 1 && $s != *ss ]]; then
    printf '%s' "${s%s}"
  else
    printf '%s' "$s"
  fi
}

# resource_base_name <path> — last non-dynamic segment.
resource_base_name() {
  local name="" seg
  local IFS=/
  local parts=($1)
  unset IFS
  for seg in ${parts[@]+"${parts[@]}"}; do
    [[ -n $seg && $seg != :* ]] || continue
    name="$seg"
  done
  [[ -n $name ]] || name="resource"
  printf '%s' "$name"
}

# A derived name becomes `def self.<name>_path`, so it must be an identifier.
# A pattern carrying characters a method name cannot take (a `#`, say) would
# otherwise be emitted as valid Ruby with a silently different name.
validate_name() {
  local name="$1" line="$2" pattern="$3"
  [[ $name =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] && return 0
  die 2 "config/routes.rb:$line: cannot derive a helper name from $pattern — give the row a \`# as: <name>\` marker"
}

# --- row collection ---------------------------------------------------------
#
# Rows are collected as "name<TAB>verb<TAB>pattern" lines.

emit_row() {
  printf '%s\t%s\t%s\n' "$1" "$2" "$3" >>"$ROWS"
}

# The `# as:` marker is a comment, so it is read from the line the row starts
# on; the AST carries start lines only, and comments are not nodes.
load_markers() {
  local lineno=0 line
  MARKERS=()
  while IFS= read -r line || [[ -n $line ]]; do
    lineno=$((lineno + 1))
    if [[ $line =~ [#][[:space:]]*as:[[:space:]]*([a-z0-9_]+) ]]; then
      MARKERS[$lineno]="${BASH_REMATCH[1]}"
    fi
  done <"$routes_file"
}

# emit_call_row <helper> <pattern> <controller> <action> <line>
emit_call_row() {
  local helper="$1" pattern="$2" controller="$3" action="$4" line="$5"
  local marker="${MARKERS[$line]:-}" name verb
  if ! helper_known "$helper"; then
    die 2 "config/routes.rb:$line: unknown helper $helper — rows are get/post/put/delete, Route.new, or resources calls"
  fi
  verb="$(helper_field "$helper" verb)"
  if [[ $action == "-" || -z $action ]]; then
    action="$(helper_field "$helper" default)"
  fi
  [[ -n $action ]] || die 2 "config/routes.rb:$line: $helper row has no action and its helper declares no default"
  name="${marker:-$(derive_name "$pattern" "$controller" "$action")}"
  validate_name "$name" "$line" "$pattern"
  emit_row "$name" "$verb" "$pattern"
}

# emit_route_row <verb> <pattern> <controller> <action> <line>
emit_route_row() {
  local verb="$1" pattern="$2" controller="$3" action="$4" line="$5"
  local marker="${MARKERS[$line]:-}" name
  name="${marker:-$(derive_name "$pattern" "$controller" "$action")}"
  validate_name "$name" "$line" "$pattern"
  emit_row "$name" "$verb" "$pattern"
}

# emit_resources_row <pattern> <controller> <only> <line> — the five RESTful
# rows of one resource, with the `only:` subset. The rows come out in REST
# order regardless of the order in `only:`.
emit_resources_row() {
  local pattern="$1" controller="$2" only="$3" line="$4"
  local base member wanted="" action name verb row_pattern
  [[ -z ${MARKERS[$line]:-} ]] ||
    die 2 "config/routes.rb:$line: # as: cannot name a resources row — name a hand-written row instead"
  [[ $only == "-" ]] || wanted="$only"
  base="$(resource_base_name "$pattern")"
  member="$(singularize_name "$base")"
  for action in index create show update destroy; do
    [[ -n $wanted && " $wanted " != *" $action "* ]] && continue
    name="$base"
    case "$action" in
      index) verb=GET; row_pattern="$pattern" ;;
      create) verb=POST; row_pattern="$pattern" ;;
      show) name="$member"; verb=GET; row_pattern="$pattern/:id" ;;
      update) name="$member"; verb=PUT; row_pattern="$pattern/:id" ;;
      destroy) name="$member"; verb=DELETE; row_pattern="$pattern/:id" ;;
    esac
    validate_name "$name" "$line" "$row_pattern"
    emit_row "$name" "$verb" "$row_pattern"
  done
}

# The reader (gen-route-helpers-ast.awk) prints helper lines first, then the
# table rows, so a local definition is known before a row that uses it.
read_items() {
  local kind a b c d e
  while IFS=$'\t' read -r kind a b c d e; do
    [[ $kind == helper ]] || continue
    [[ -n $b ]] || die 2 "config/routes.rb: helper $a does not build a Route row"
    learn_helper "$a" "$b" "$c"
  done <"$ITEMS"
  while IFS=$'\t' read -r kind a b c d e; do
    case "$kind" in
      call) emit_call_row "$a" "$b" "$c" "$d" "$e" ;;
      route) emit_route_row "$a" "$b" "$c" "$d" "$e" ;;
      resources) emit_resources_row "$a" "$b" "$c" "$d" ;;
    esac
  done <"$ITEMS"
}

# --- arguments --------------------------------------------------------------

check=0
app_root=""
for arg in "$@"; do
  case "$arg" in
    --check)
      check=1
      ;;
    -*)
      die 2 "usage: snails gen-route-helpers <app_root> [--check]"
      ;;
    *)
      if [[ -n $app_root ]]; then
        die 2 "usage: snails gen-route-helpers <app_root> [--check]"
      fi
      app_root="$arg"
      ;;
  esac
done
if [[ -z $app_root ]]; then
  app_root="$(resolve_app_root '[snails]' '<app_root>')" || exit 2
else
  # An explicit argument may be the repository root of a src/ layout; when
  # the argument is omitted, resolve_app_root applies the same rule.
  app_root="$(app_root_for "$app_root")"
fi
[[ -d $app_root ]] || die 2 "no such app root: $app_root — pass the directory that holds config/database.rb"
while [[ $app_root == */ && $app_root != / ]]; do
  app_root="${app_root%/}"
done

routes_file="$app_root/config/routes.rb"
[[ -f $routes_file ]] || die 2 "no route table: $routes_file"

gen_dir="$app_root/gen"
[[ -d $gen_dir ]] || die 2 "no gen/ directory: $gen_dir"

out="$gen_dir/route_helpers.rb"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
ROWS="$tmp/rows"
ITEMS="$tmp/items"
: >"$ROWS"
: >"$ITEMS"

# The parser is the toolchain the app already builds with: the pins file's
# SPINEL_REV decides which spinel reads the routes.
# shellcheck source=toolchain.sh
source "$GEN_SCRIPTS/toolchain.sh"
pins="$(pins_discover "$app_root")"
[[ -n $pins ]] ||
  die 2 "no pins file above $app_root — the route parser runs the pinned spinel; add a pins.toml (snails new stamps one)"
spinel_toolchain_ensure "$pins" ||
  die 2 "the pinned spinel toolchain is unavailable — see the message above"
spinel_bin="$(spinel_toolchain_dir "$pins")/spinel"
"$spinel_bin" --dump-ast "$routes_file" >"$tmp/dump" 2>"$tmp/dump.err" || {
  die 2 "config/routes.rb: spinel could not parse it — $(head -n 1 "$tmp/dump.err")"
}
awk -f "$GEN_SCRIPTS/gen-route-helpers-ast.awk" "$tmp/dump" >"$ITEMS" || exit 2

load_markers
read_items

[[ -s $ROWS ]] || die 2 "no route rows read from $routes_file"

# Dedupe identical rows and refuse colliding names (same name, different
# pattern). One of them would have to win, and a helper that returns the other
# row's path is the silent failure this generator exists to prevent.
if ! awk -F'\t' '
  {
    name = $1
    if (name in first) {
      if (first[name] != $3) bad[name] = bad[name] " · " $2 " " $3
      next
    }
    first[name] = $3
    firstline[name] = $2 " " $3
    order[++n] = name
    kept[name] = $1 "\t" $2 "\t" $3
  }
  END {
    if (length(bad) > 0) {
      for (k in bad) printf "config/routes.rb: %s is derived from more than one pattern (%s%s)\n", k, firstline[k], bad[k] > "/dev/stderr"
      exit 3
    }
    for (i = 1; i <= n; i++) print kept[order[i]]
  }
' "$ROWS" >"$tmp/kept"; then
  die 2 "two routes derive the same helper name — add \`# as: <name>\` to one of them"
fi

rows_count="$(wc -l <"$ROWS" | tr -d ' ')"
kept_count="$(wc -l <"$tmp/kept" | tr -d ' ')"

# --- render -----------------------------------------------------------------

# path_expr <pattern> — literal-plus-params expression for a dynamic
# pattern: "/devices/:id" -> "\"/devices/\" + id.to_s".
path_expr() {
  local rest="$1" before name out=""
  while [[ $rest =~ ^([^:]*):([a-z_][A-Za-z0-9_]*)(.*)$ ]]; do
    before="${BASH_REMATCH[1]}"
    name="${BASH_REMATCH[2]}"
    rest="${BASH_REMATCH[3]}"
    [[ -n $before ]] && out="$out\"$before\" + "
    out="$out$name.to_s + "
  done
  if [[ -n $rest ]]; then
    out="$out\"$rest\""
  else
    out="${out% + }"
  fi
  printf '%s' "$out"
}

render() {
  local name verb pattern params p expr first=1
  printf '# Generated by `snails gen-route-helpers` from config/routes.rb — do not edit.\n'
  printf '#\n'
  printf '# %s rows -> %s helpers; a name derives from its pattern (`login_path` for /login).\n' "$rows_count" "$kept_count"
  printf 'module RouteHelpers\n'
  while IFS=$'\t' read -r name verb pattern; do
    [[ -n $name ]] || continue
    if ((first)); then
      first=0
    else
      printf '\n'
    fi
    params=""
    local IFS=/
    local segs=($pattern)
    unset IFS
    for p in ${segs[@]+"${segs[@]}"}; do
      [[ $p == :* ]] || continue
      p="${p#:}"
      if [[ -z $params ]]; then
        params="$p"
      else
        params="$params, $p"
      fi
    done
    printf '  # %s %s\n' "$verb" "$pattern"
    if [[ -n $params ]]; then
      printf '  def self.%s_path(%s)\n' "$name" "$params"
      printf '    %s\n' "$(path_expr "$pattern")"
    else
      printf '  def self.%s_path\n' "$name"
      printf '    "%s"\n' "$pattern"
    fi
    printf '  end\n'
  done <"$tmp/kept"
  printf 'end\n'
}

render >"$tmp/out"

if ((check)); then
  if cmp -s "$tmp/out" "$out"; then
    exit 0
  fi
  repair_arg="$(app_root_argument "$app_root")"
  gen_command="snails gen-route-helpers"
  [[ -n $repair_arg ]] && gen_command+=" $(shell_quote "$repair_arg")"
  die 1 "gen/route_helpers.rb does not match config/routes.rb — run: $gen_command"
else
  if cmp -s "$tmp/out" "$out"; then
    exit 0
  fi
  cat "$tmp/out" >"$out"
  echo "[snails] regenerated: gen/route_helpers.rb ($rows_count rows)"
fi
