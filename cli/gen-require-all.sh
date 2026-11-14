#!/bin/bash
# Regenerate the require lists in gen/* from a folder scan.
#
# spinel is AOT: it analyses the require graph statically. A require that
# is not a literal — one reached through a Dir.glob loop or an array walk —
# silently drops out of the graph and surfaces only as a runtime NameError.
# There is no "require a folder" either, so the only reliable way to load a
# whole folder is to generate the literal require list.
#
# Layout: the spec and its output share a marker region inside one file,
# gen/<group>.rb. The boot chain requires that file, so the spec sits
# directly above the load path, and the generated requires use a path
# relative to the spec file (../app/), so every file points at the same app/.
# gen/ is committed source (the spec is the source; gitignoring it breaks a
# fresh clone), and the split from the local-output tmp/ is deliberate.
# Outside the region (header comments), the file is app-owned.
#
#   # >>> snails generate
#   # scan: models/concerns/**    spec — glob relative to app/, order = load order
#   # scan: models/**
#   require_relative "../app/models/concerns/auditing"      generated
#   # <<< snails generate
#
# Files that no spec covers are excluded by default. Excluding a file is not
# a workaround; it is a declaration: a file you meant to leave out (say
# app/route_helpers.rb) is simply not listed.
#
# A trailing `**` does not recurse: use `group/**/*` for the recursive form.
# A spec like `models/**` sees direct children only.
#
# Content-gated write: an identical result leaves the file untouched.
# The harness bundle runner (cli/spin-test.sh) decides its cache
# from source mtimes, so refreshing mtimes on every run would recompile
# the whole graph each time.
#
# Usage:
#   bash cli/gen-require-all.sh [<app_root>]          regenerate (writes only on change)
#   bash cli/gen-require-all.sh [<app_root>] --check  freshness check only
#   --verbose  with --check: list every stale file (default: a one-line report)
#   <app_root> omitted resolves through cli/app-root.sh (nearest app root
#   at or above $PWD; outside the app, pass it).
#
# Exit: 0 = in sync · 1 = stale (--check) · 2 = structural error (usage, damaged markers)
set -euo pipefail

# App-root resolution is shared with the CLI and the other engines.
GEN_SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=app-root.sh
source "$GEN_SCRIPTS/app-root.sh"
# shellcheck source=vendor-dir.sh
source "$GEN_SCRIPTS/vendor-dir.sh"

BEGIN_MARK="# >>> snails generate"
END_MARK="# <<< snails generate"
# The scaffold default — used when the tree has neither a vendored core
# boot nor a legacy app boot (fixtures, staging). A tree with a boot is
# judged by that boot: an app pinned before a group existed must keep
# generating with its own boot, so a newer CLI never demands a file its
# boot does not load.
CORE="lib controllers helpers mailers models forms jobs services"
# Spec files live in <app_root>/gen/, scan targets in <app_root>/app/ —
# one step up reaches the same app_root.
REL_PREFIX="../app/"

die() {
  local code="$1"
  shift
  echo "[snails] $*" >&2
  exit "$code"
}

# --- scan glob --------------------------------------------------------------
#
# The subset of glob the scan specs use: '/'-separated components; a whole
# `**` component recurses when more components follow (a trailing `**`
# matches one level, like `*`); `*`/`?`/`[...]` match within one component;
# hidden entries are excluded unless the component starts with a dot.
# Brace expansion is not part of the subset — no spec relies on it.

# list_level <dir> — print the direct entries of <dir> (the trailing-`**`
# form; a hidden entry is not matched, like a `*`).
list_level() {
  local entry
  for entry in "$1"/*; do
    [[ -e $entry ]] || continue
    printf '%s\n' "$entry"
  done
}

# list_all <dir> — print every direct entry, hidden ones included (the
# `.`/`..` pseudo-entries are not children; a component pattern decides
# whether a hidden name matches).
list_all() {
  local entry
  for entry in "$1"/* "$1"/.[!.]* "$1"/..?*; do
    [[ -e $entry ]] || continue
    printf '%s\n' "$entry"
  done
}

# glob_levels <dir> <component...> — the `**/` form: the remaining
# components at this level and at every level below it (zero or more
# directories; the walk does not descend into hidden directories).
glob_levels() {
  local dir="$1" entry
  shift
  glob_walk "$dir" "$@"
  for entry in "$dir"/*; do
    if [[ -d $entry && ${entry##*/} != .* ]]; then
      glob_levels "$entry" "$@"
    fi
  done
}

# glob_walk <dir> <component...> — print every path under <dir> matching
# the remaining components (unsorted; callers sort).
glob_walk() {
  local dir="$1" comp entry name
  shift
  (($#)) || return 0
  comp="$1"
  shift

  if [[ $comp == "**" ]]; then
    if (($#)); then
      glob_levels "$dir" "$@"
    else
      list_level "$dir"
    fi
  elif [[ $comp == *"*"* || $comp == *"?"* || $comp == *"["* ]]; then
    while IFS= read -r entry; do
      name="${entry##*/}"
      if [[ $name == .* && $comp != .* ]]; then
        continue
      fi
      # shellcheck disable=SC2053  # the right side is a pattern here — matching it is the point
      if [[ $name == $comp ]]; then
        printf '%s\n' "$entry"
        if (($#)) && [[ -d $entry ]]; then
          glob_walk "$entry" "$@"
        fi
      fi
    done < <(list_all "$dir")
  else
    if [[ -e $dir/$comp ]]; then
      printf '%s\n' "$dir/$comp"
      if (($#)) && [[ -d $dir/$comp ]]; then
        glob_walk "$dir/$comp" "$@"
      fi
    fi
  fi
}

# glob_scan <base> <pattern> — print the paths under <base> matching
# <pattern> (unsorted).
glob_scan() {
  local comps=()
  IFS=/ read -r -a comps <<<"$2"
  glob_walk "$1" ${comps[@]+"${comps[@]}"}
}

# matched_rb <base> <pattern> — print the .rb files matching <pattern>,
# byte-sorted. Directories and non-Ruby entries are not part of a group.
matched_rb() {
  local path
  while IFS= read -r path; do
    if [[ -f $path && $path == *.rb ]]; then
      printf '%s\n' "$path"
    fi
  done < <(glob_scan "$1" "$2" | LC_ALL=C sort)
}

# literal_prefix <pattern> — the literal prefix before the first wildcard
# character: the directory part named by a scan pattern.
literal_prefix() {
  if [[ $1 =~ ^([^*?[]*)[*?[] ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  else
    printf '%s' "$1"
  fi
}

# list_has <list> <item> — membership over a newline-separated list.
list_has() {
  [[ $'\n'"$1"$'\n' == *$'\n'"$2"$'\n'* ]]
}

# required_groups <app_root> — the require-all groups the boot chain
# requires, one per line. The vendored core boot is the authority; a tree
# pinned before the core boot existed keeps its app boot as the authority.
# Without either, or without any gen require in the boot, the scaffold
# default applies. route_helpers is skipped — it has its own generator and
# no scan spec, so its presence stays verify-scaffold's contract.
required_groups() {
  local app_root="$1" boot name found=""
  for boot in "$app_root/$SNAILS_VENDOR_DIR/boot.rb" "$app_root/runtime/boot.rb" "$app_root/boot.rb"; do
    [[ -f $boot ]] || continue
    while IFS= read -r name; do
      [[ $name == route_helpers ]] && continue
      found="$found$name"$'\n'
    done < <(sed -n -e 's/^require_relative "gen\/\([A-Za-z0-9_]*\)"$/\1/p' \
                     -e 's/^require_relative "\.\.\/gen\/\([A-Za-z0-9_]*\)"$/\1/p' "$boot")
    # The vendored core boot entry is the authority even when it names no
    # group: the selected profile requires config/codegen.rb, and the core
    # default list applies. A legacy runtime/ boot is the same authority;
    # only a tree without either falls back to its app boot.
    if [[ $boot == "$app_root/$SNAILS_VENDOR_DIR/boot.rb" || $boot == "$app_root/runtime/boot.rb" ]]; then
      break
    fi
    if [[ -n $found ]]; then
      break
    fi
  done
  if [[ -z $found ]]; then
    printf '%s\n' $CORE
  else
    printf '%s\n' "$found"
  fi
}

# build_region <app_dir> <pattern...> — print the regenerated region body:
# the scan spec lines in spec order, then one require per matched file
# (the first pattern to match a file wins; each file is required once).
# A literal parent directory that matches nothing is likely a typo, so
# warn (a pattern whose directory does not exist is just an empty group).
build_region() {
  local app_dir="$1" pattern path rel literal seen="" matched_any
  shift
  for pattern in "$@"; do
    printf '# scan: %s\n' "$pattern"
  done
  for pattern in "$@"; do
    matched_any=0
    while IFS= read -r path; do
      matched_any=1
      if list_has "$seen" "$path"; then
        continue
      fi
      seen="$seen$path"$'\n'
      rel="${path#"$app_dir"/}"
      printf 'require_relative "%s%s"\n' "$REL_PREFIX" "${rel%.rb}"
    done < <(matched_rb "$app_dir" "$pattern")
    if ((matched_any == 0)); then
      literal="$(literal_prefix "$pattern")"
      if [[ -n $literal && -d "$app_dir/$literal" ]]; then
        echo "[snails] scan matched nothing: $pattern" >&2
      fi
    fi
  done
}

# --- arguments --------------------------------------------------------------

check=0
verbose=0
app_root=""
for arg in "$@"; do
  case "$arg" in
    --check)
      check=1
      ;;
    --verbose)
      verbose=1
      ;;
    -*)
      die 2 "usage: snails gen-require-all <app_root> [--check] [--verbose]"
      ;;
    *)
      if [[ -n $app_root ]]; then
        die 2 "usage: snails gen-require-all <app_root> [--check] [--verbose]"
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
if ((verbose && !check)); then
  die 2 "--verbose applies to '--check' — it lists the stale files"
fi
[[ -d $app_root ]] || die 2 "no such app root: $app_root — pass the directory that holds config/database.rb"
while [[ $app_root == */ && $app_root != / ]]; do
  app_root="${app_root%/}"
done

app_dir="$app_root/app"
[[ -d $app_dir ]] || die 2 "no app/ directory: $app_dir — pass the app root (the directory that holds app/)"

gen_dir="$app_root/gen"
if [[ ! -d $gen_dir ]]; then
  repair_arg="$(app_root_argument "$app_root")"
  sync_command="snails sync"
  [[ -n $repair_arg ]] && sync_command+=" $(shell_quote "$repair_arg")"
  die 2 "no gen/ directory: $gen_dir — run: $sync_command to seed it"
fi

REQUIRED="$(required_groups "$app_root")"
for name in $REQUIRED; do
  [[ -f "$gen_dir/$name.rb" ]] || {
    repair_arg="$(app_root_argument "$app_root")"
    sync_command="snails sync"
    [[ -n $repair_arg ]] && sync_command+=" $(shell_quote "$repair_arg")"
    die 2 "the boot chain requires gen/$name.rb but it is missing — run: $sync_command to seed it (or restore the file)"
  }
done

# --- regenerate -------------------------------------------------------------

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

stale=""
regenerated=""

gen_files=()
for path in "$gen_dir"/*.rb; do
  [[ -f $path ]] || continue
  gen_files+=("$path")
done

if ((${#gen_files[@]})); then
  while IFS= read -r path; do
    rel="${path#"$app_root"/}"

    has_begin=0
    if grep -qF -- "$BEGIN_MARK" "$path"; then
      has_begin=1
    fi
    stem="${path##*/}"
    stem="${stem%.rb}"
    if list_has "$REQUIRED" "$stem" && [[ " $CORE " == *" $stem "* ]] && ((has_begin == 0)); then
      die 2 "$rel: missing the generator markers \"$BEGIN_MARK\" and \"$END_MARK\" — restore the pair, or delete the file and rerun snails sync"
    fi
    if ((has_begin == 0)); then
      continue
    fi

    lines=()
    begin_count=0
    end_count=0
    begin_idx=-1
    end_idx=-1
    idx=0
    while IFS= read -r line || [[ -n $line ]]; do
      lines+=("$line")
      if [[ $line == "$BEGIN_MARK" ]]; then
        begin_count=$((begin_count + 1))
        begin_idx=$idx
      fi
      if [[ $line == "$END_MARK" ]]; then
        end_count=$((end_count + 1))
        end_idx=$idx
      fi
      idx=$((idx + 1))
    done <"$path"

    if ((begin_count != 1 || end_count != 1 || end_idx <= begin_idx)); then
      die 2 "$rel: the generator markers must appear exactly once in order (\"$BEGIN_MARK\" before \"$END_MARK\") — restore the pair, or delete the file and rerun snails sync"
    fi

    scans=()
    i=$((begin_idx + 1))
    while ((i < end_idx)); do
      body="${lines[$i]}"
      if [[ -n $body ]]; then
        if [[ $body =~ ^#[[:space:]]*scan:[[:space:]]*([^[:space:]]+)[[:space:]]*$ ]]; then
          scans+=("${BASH_REMATCH[1]}")
        elif [[ $body != "require_relative "* ]]; then
          # require_relative is generated output and is rewritten on the
          # next run (a mismatch shows up as regenerated/stale). Anything
          # else is a hand edit inside a generator-owned region, which is
          # an error.
          die 2 "$rel: the generator owns the lines between its markers — move the hand edit outside the markers: $body"
        fi
      fi
      i=$((i + 1))
    done

    {
      i=0
      while ((i <= begin_idx)); do
        printf '%s\n' "${lines[$i]}"
        i=$((i + 1))
      done
      build_region "$app_dir" ${scans[@]+"${scans[@]}"}
      i=$((end_idx))
      while ((i < ${#lines[@]})); do
        printf '%s\n' "${lines[$i]}"
        i=$((i + 1))
      done
    } >"$tmp/out"

    if cmp -s "$tmp/out" "$path"; then
      continue
    fi
    if ((check)); then
      stale="$stale$rel"$'\n'
    else
      cat "$tmp/out" >"$path"
      regenerated="$regenerated$rel"$'\n'
    fi
  done < <(printf '%s\n' ${gen_files[@]+"${gen_files[@]}"} | LC_ALL=C sort)
fi

if ((check)); then
  if [[ -n $stale ]]; then
    stale_count="$(printf '%s\n' "$stale" | grep -c . || true)"
    repair_arg="$(app_root_argument "$app_root")"
    gen_command="snails gen-require-all"
    [[ -n $repair_arg ]] && gen_command+=" $(shell_quote "$repair_arg")"
    echo "[snails] $app_root is stale ($stale_count file(s)) — run: $gen_command" >&2
    if ((verbose)); then
      while IFS= read -r rel; do
        [[ -n $rel ]] || continue
        echo "[snails]   stale: $rel" >&2
      done <<<"$stale"
    fi
    exit 1
  fi
else
  while IFS= read -r rel; do
    [[ -n $rel ]] || continue
    echo "[snails] regenerated: $rel"
  done <<<"$regenerated"
fi
