#!/bin/bash
# Generate model column readers and constants from db/schema.sql.
#
# Why generate: spinel AOT unrolls `define_method` only for a literal array
# in a class body, so Sqlx::Base cannot create per-model readers from a
# constant. The schema is the one source for column names; a hand-written
# list drifts. Every Sqlx::Base model under app/models is generated
# automatically; the model keeps only its table name and domain methods.
#
# What it reads: db/schema.sql (CREATE TABLE only) and the model files under
# app/models (subfolders included). Ruby is read by the pinned spinel's
# parser — `spinel --dump-ast` — not by this script, so a heredoc or a block
# comment can never be mistaken for a declaration. The generated file reopens
# the class where it was declared, so a model's folder is a layout choice; a
# model anywhere else under app/ is reported, not generated. The generated file reopens each model to extend
# the column metadata module and include the reader module. A method the
# model defines itself wins over an included module method, so domain readers
# stay; they are also excluded from the generated reader and rbs so the types
# do not collide.
#
# The parser is part of the toolchain the app already builds with: the pins
# file's SPINEL_REV decides which spinel reads the models. A tree without a
# pins file cannot generate — the pin is what makes the parse reproducible.
#
# Outputs:
#   gen/model_columns.rb   — COLUMNS, only_columns/datetime_columns/
#                            date_columns/boolean_columns/json_columns,
#                            reader modules, class attach
#   gen/model_columns.rbs  — type seeds for the same modules
#
# Content-gated write: an identical result leaves the files untouched.
#
# Usage:
#   bash cli/gen-model-columns.sh [<app_root>]          regenerate (writes only on change)
#   bash cli/gen-model-columns.sh [<app_root>] --check  freshness check only
#   <app_root> omitted resolves through cli/app-root.sh.
#
# Exit: 0 in sync · 1 stale (--check) · 2 structural error (usage, unreadable schema/model,
#       model whose declared namespace disagrees with its path, unparseable model file)
set -euo pipefail

GEN_SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=app-root.sh
source "$GEN_SCRIPTS/app-root.sh"
# shellcheck source=vendor-dir.sh
source "$GEN_SCRIPTS/vendor-dir.sh"

die() {
  local code="$1"
  shift
  echo "[snails] $*" >&2
  exit "$code"
}

check=0
app_root=""
for arg in "$@"; do
  case "$arg" in
    --check)
      check=1
      ;;
    -h|--help)
      echo "usage: snails gen-model-columns [<app_root>] [--check]"
      exit 0
      ;;
    -*)
      die 2 "usage: snails gen-model-columns [<app_root>] [--check]"
      ;;
    *)
      if [[ -n $app_root ]]; then
        die 2 "usage: snails gen-model-columns [<app_root>] [--check]"
      fi
      app_root="$arg"
      ;;
  esac
done
if [[ -z $app_root ]]; then
  app_root="$(resolve_app_root '[snails]' '<app_root>')" || exit 2
else
  # An explicit argument may be the repository root of a src/ layout; the
  # omitted case resolves the same root through resolve_app_root.
  app_root="$(app_root_for "$app_root")"
fi
[[ -d $app_root ]] || die 2 "no such app_root: $app_root"
while [[ $app_root == */ && $app_root != / ]]; do
  app_root="${app_root%/}"
done

schema_file="$app_root/db/schema.sql"
app_dir="$app_root/app"
models_dir="$app_root/app/models"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
model_files="$tmp/model_files"
facts_file="$tmp/model_facts"
stray_file="$tmp/stray_facts"
: >"$model_files"
: >"$facts_file"
: >"$stray_file"

if [[ ! -d $app_dir ]]; then
  exit 0
fi

# A Sqlx::Base model must name its superclass, so a file that never mentions
# Sqlx cannot be one. This keeps the parser off every unrelated app file
# without reading Ruby text here.
while IFS= read -r file; do
  if grep -q 'Sqlx' "$file"; then
    printf '%s\n' "$file" >>"$model_files"
  fi
done < <(find "$app_dir" -type f -name '*.rb' | sort)
candidate_count="$(wc -l <"$model_files" | tr -d ' ')"

# A project without a schema or a model has nothing to generate. Minimal
# scaffolds are in this state; the boot chain still requires the seed
# placeholder, so a no-op keeps that file intact.
if [[ ! -f $schema_file ]]; then
  if [[ -d $models_dir ]] && grep -R -q 'Sqlx' "$models_dir"; then
    repair_arg="$(app_root_argument "$app_root")"
    dump_command="snails migrate dump"
    [[ -n $repair_arg ]] && dump_command+=" $(shell_quote "$repair_arg")"
    die 2 "Sqlx::Base model found but no schema file: $schema_file — run: $dump_command"
  fi
  exit 0
fi

gen_dir="$app_root/gen"
[[ -d $gen_dir ]] || die 2 "no gen/ directory: $gen_dir"

out_rb="$gen_dir/model_columns.rb"
out_rbs="$gen_dir/model_columns.rbs"

spinel_bin=""
ensure_toolchain() {
  if [[ -n $spinel_bin ]]; then
    return 0
  fi
  # shellcheck source=toolchain.sh
  source "$GEN_SCRIPTS/toolchain.sh"
  local pins
  pins="$(pins_discover "$app_root")"
  if [[ -z $pins ]]; then
    die 2 "no pins file above $app_root — the model parser runs the pinned spinel; add a pins.toml (snails new stamps one)"
  fi
  spinel_toolchain_ensure "$pins" ||
    die 2 "the pinned spinel toolchain is unavailable — see the message above"
  spinel_bin="$(spinel_toolchain_dir "$pins")/spinel"
}

# One model file per invocation: the declared class, table, and overrides come
# from the AST, and the emitter re-checks the declared namespace against the
# path. A file that does not parse is a structural error — the build would
# fail later with a less useful message.
parse_models() {
  local file dump="$tmp/dump"
  while IFS= read -r file; do
    [[ $file == "$models_dir"/* ]] || continue
    "$spinel_bin" --dump-ast "$file" >"$dump" 2>"$tmp/dump.err" || {
      die 2 "$file: spinel could not parse it — $(head -n 1 "$tmp/dump.err")"
    }
    awk -f "$GEN_SCRIPTS/gen-model-columns-ast.awk" "$dump" >>"$facts_file" || exit 2
  done <"$model_files"
}

# The attach target comes from the path under app/models, so a model filed
# anywhere else would never get its columns. Report it instead of letting it
# vanish from the output. The probe stays silent on a file it cannot read: a
# stray is a layout mistake, not a parse contract.
probe_strays() {
  local file dump="$tmp/dump"
  while IFS= read -r file; do
    [[ $file == "$models_dir"/* ]] && continue
    "$spinel_bin" --dump-ast "$file" >"$dump" 2>/dev/null || continue
    awk -v probe=1 -f "$GEN_SCRIPTS/gen-model-columns-ast.awk" "$dump" >>"$stray_file" || continue
  done <"$model_files"
}

if ((candidate_count > 0)); then
  ensure_toolchain
  parse_models
  probe_strays
  stray_count="$(wc -l <"$stray_file" | tr -d ' ')"
  if ((stray_count > 0)); then
    stray_paths="$(cut -f1 "$stray_file" | sed 's/^/ /' | tr -d '\n')"
    echo "[snails] ignored $stray_count Sqlx::Base model(s) outside app/models:$stray_paths — move them under app/models/" >&2
  fi
fi

# No app/models directory means nothing is attached; the stray report above
# still ran, and no generated file appears where the boot chain expects one.
if [[ ! -d $models_dir ]]; then
  exit 0
fi

awk -v vendor_dir="$SNAILS_VENDOR_DIR" \
  -f "$GEN_SCRIPTS/gen-model-columns.awk" \
  -v schema="$schema_file" \
  -v facts="$facts_file" \
  -v out_rb="$tmp/model_columns.rb" \
  -v out_rbs="$tmp/model_columns.rbs" || exit $?

if ((check)); then
  if cmp -s "$tmp/model_columns.rb" "$out_rb" &&
     cmp -s "$tmp/model_columns.rbs" "$out_rbs"; then
    exit 0
  fi
  repair_arg="$(app_root_argument "$app_root")"
  gen_command="snails gen-model-columns"
  [[ -n $repair_arg ]] && gen_command+=" $(shell_quote "$repair_arg")"
  die 1 "gen/model_columns.rb or .rbs is stale — run: $gen_command"
fi

changed=0
if ! cmp -s "$tmp/model_columns.rb" "$out_rb"; then
  cat "$tmp/model_columns.rb" >"$out_rb"
  changed=1
fi
if ! cmp -s "$tmp/model_columns.rbs" "$out_rbs"; then
  cat "$tmp/model_columns.rbs" >"$out_rbs"
  changed=1
fi

if ((changed)); then
  models="$(grep -c 'COLUMNS = GeneratedModelColumns::' "$tmp/model_columns.rb" || true)"
  echo "[snails] regenerated: gen/model_columns.rb, gen/model_columns.rbs (${models} models)"
fi
