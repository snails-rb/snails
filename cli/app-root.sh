# App-root resolution for every surface that takes an app root — one source
# for the rule (bin/snails sync|harness|verify-scaffold|verify-pins|pins-path|gen-*,
# cli/migrate.sh, cli/generate.sh, and the three build engines).
#
# The app root is the directory carrying the database configuration (config/database.rb,
# or the retired config/db.rb) — the file database_adapter_for reads, so the
# directory holding it IS the app root. The pins file lives there too (one
# pins file per app, at that app root), so resolution never leaves the app:
# walk up from the start directory, nearest wins. The walk stops at the worktree root (the
# directory holding .git), the same bound pins discovery uses.
#
# The omitted and explicit halves share one rule: the app lives at the named
# directory, or at its standard src/ child. An omitted resolution starts at
# $PWD and walks up; when $PWD itself is the repository root (it carries
# .git) and <repo>/src is an app, that src/ child is the app. Only that fixed
# child is considered — an arbitrary project scan would pick one app among
# many. Any other directory outside the app still needs to be named.
#
# Sourced (never executed):
#   resolve_app_root <label> <fix-hint> [pins-file] — print the resolved app
#     root on stdout. The walk-up result wins; when $PWD is the repository
#     root of the standard src/ layout, <repo>/src is the app. A resolution
#     that leaves $PWD announces itself on stderr; on failure the function
#     prints one line and returns 1. The label carries its own separator so
#     each surface keeps its convention (`[snails]` everywhere; engine phase
#     names stay in the sentence). The line ends with the caller's fix hint.
#     With `--pins FILE` the pins file's directory is the app root, so that
#     directory is what resolves — and it must be an app.
#   app_root_for <dir> — the app root a caller-named directory stands for:
#     <dir> itself when it is an app, <dir>/src when the app lives there
#     (the src/ layout), else <dir> unchanged. This is the EXPLICIT-argument
#     half of the rule; resolve_app_root applies the same fixed src/ child
#     when the caller starts at that repository root. It reads no environment
#     — an explicit --app DIR or positional argument is what the caller asked
#     for.
#   is_app_root <dir> — does this directory carry the database configuration?
#   shortest_path <absolute-path> · shell_quote <argument> ·
#   app_root_argument <app-root> — render a repair command for the current
#     shell: the shortest path that resolves to the app, shell quoting, and
#     no app-root argument when $PWD already is the app root.
# shellcheck shell=bash

# is_app_root <dir> — the directory carries the database configuration, the
# file that makes a directory an app root.
is_app_root() { # <dir>
  [[ -f "$1/config/database.rb" || -f "$1/config/db.rb" ]]
}

# app_root_for <dir> — the app root that <dir> stands for: <dir> itself when
# it is an app, <dir>/src when the app lives there, else <dir> unchanged.
#
# This is the explicit-argument half of the app-root rule: a caller that
# names a directory gets the app that directory holds, including the src/
# layout where the repository root holds the app one level down. The
# omitted half (resolve_app_root) applies the same fixed src/ child when
# the caller starts at that repository root — see the file header.
#
# The marker is is_app_root, the same test resolution uses, so there is one
# definition of "app root". It reads no environment and never fails: an
# explicit argument is what the caller asked for, and the caller validates
# the directory it gets back.
app_root_for() { # <dir>
  local dir="$1"
  if is_app_root "$dir"; then
    printf '%s' "$dir"
  elif is_app_root "$dir/src"; then
    printf '%s' "$dir/src"
  else
    printf '%s' "$dir"
  fi
}

app_root_at_or_above() { # <dir>
  local cur="$1" parent
  while :; do
    if is_app_root "$cur"; then
      printf '%s' "$cur"
      return 0
    fi
    [[ -e "$cur/.git" ]] && return 1
    parent="$(dirname "$cur")"
    [[ $parent == "$cur" ]] && return 1
    cur="$parent"
  done
}

# app_root_in_src_layout <dir> — the app a repository root holds in the
# standard src/ layout. The markers are <dir> itself being the repository
# root (.git) and <dir>/src being an app. A subdirectory other than the
# repository root is not a candidate: descending from an arbitrary place
# would pick one app among many.
app_root_in_src_layout() { # <dir>
  local dir="$1"
  [[ -e "$dir/.git" ]] || return 1
  is_app_root "$dir/src" || return 1
  printf '%s' "$dir/src"
}

resolve_app_root() { # <label> <fix-hint> [pins-file]
  local label="$1" fix="$2" pins="${3:-}" app project
  if app="$(app_root_at_or_above "$PWD")"; then
    if [[ $app != "$PWD" ]]; then
      echo "$label app root $app (auto-resolved)" >&2
    fi
    printf '%s' "$app"
    return 0
  fi
  # The repository root of the standard src/ layout names the app it holds.
  # Only that fixed child is considered — the caller is at the project entry
  # point, not inside some subdirectory, so this is not a project scan.
  if app="$(app_root_in_src_layout "$PWD")"; then
    echo "$label app root $app (auto-resolved)" >&2
    printf '%s' "$app"
    return 0
  fi
  # Outside every app. An explicit --pins names the pins file, and the pins
  # file sits at the app root, so its directory is the app.
  if [[ -n $pins ]]; then
    if ! project="$(cd "$(dirname "$pins")" 2>/dev/null && pwd)"; then
      echo "$label pins file not found: $pins" >&2
      return 1
    fi
    if ! is_app_root "$project"; then
      echo "$label $project holds the pins file but is not an app root (looked for config/database.rb) — pins.toml belongs in the app root, or pass $fix" >&2
      return 1
    fi
    echo "$label app root $project (auto-resolved)" >&2
    printf '%s' "$project"
    return 0
  fi
  echo "$label no app root at or above $PWD (looked for config/database.rb) — pass $fix" >&2
  return 1
}

# The repair line runs in the shell that saw the failure, so print the
# shortest path that resolves there: a relative path, or the absolute one
# when it is shorter or does not resolve back to the app. A symlinked $PWD
# makes the kernel's `..` differ from the logical path, so a string-only
# relative path is not enough.
shortest_path() { # <absolute-path>
  local target="$1" rel="" i common=0
  local -a target_parts=() pwd_parts=()
  IFS=/ read -r -a target_parts <<<"${target#/}"
  IFS=/ read -r -a pwd_parts <<<"${PWD#/}"
  while ((common < ${#target_parts[@]} && common < ${#pwd_parts[@]})) &&
        [[ ${target_parts[$common]} == "${pwd_parts[$common]}" ]]; do
    common=$((common + 1))
  done
  for ((i = common; i < ${#pwd_parts[@]}; i++)); do
    rel+="../"
  done
  for ((i = common; i < ${#target_parts[@]}; i++)); do
    rel+="${target_parts[$i]}/"
  done
  rel="${rel%/}"
  [[ -n $rel ]] || rel="."
  if ((${#rel} <= ${#target})) &&
     [[ -d $rel ]] &&
     [[ "$(cd -- "$rel" 2>/dev/null && pwd)" == "$target" ]] &&
     [[ "$(cd -- "$rel" 2>/dev/null && pwd -P)" == "$(cd -- "$target" 2>/dev/null && pwd -P)" ]]; then
    printf '%s' "$rel"
  else
    printf '%s' "$target"
  fi
}

# Quote an argument only when it needs quoting; the common command stays
# readable, and a path with spaces or quotes still survives copy-paste.
shell_quote() { # <argument>
  local arg="$1" out="" i char
  if [[ $arg =~ ^[A-Za-z0-9_./:@%+=,-]+$ ]]; then
    printf '%s' "$arg"
    return 0
  fi
  out="'"
  for ((i = 0; i < ${#arg}; i++)); do
    char="${arg:i:1}"
    if [[ $char == "'" ]]; then
      out+="'\\''"
    else
      out+="$char"
    fi
  done
  out+="'"
  printf '%s' "$out"
}

# Print the app-root argument for a repair command: nothing when the current
# directory is the app root (the resolver finds it again), otherwise the
# shortest path that resolves back to it. Callers shell-quote the result.
app_root_argument() { # <app-root>
  local app_root="$1" absolute
  if [[ ! -d $app_root ]]; then
    printf '%s' "$app_root"
    return 0
  fi
  absolute="$(cd -- "$app_root" 2>/dev/null && pwd)" || {
    printf '%s' "$app_root"
    return 0
  }
  if [[ $absolute == "$PWD" ]]; then
    return 0
  fi
  shortest_path "$absolute"
}
