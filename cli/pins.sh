# pins file resolution: where a project's pins file is, and how to read one
# KEY from it. The CLI (bin/snails) and the engines (cli/toolchain.sh,
# cli/harness-dev.sh) share both parts, so there is no second copy of the
# directory walk or the format parser to drift.
#
# Location rule: the pins file sits at the app root — one pins file per app,
# in the directory that carries the database configuration — so the nearest
# pins.toml at or above <dir> is that file whenever the walk starts inside
# the app. The walk stops at the directory that holds .git: a pins file is a
# project-level declaration, so it never leaves the repository.
#
# Format rule: flat KEY="value" (legacy KEY=value), comments and blank lines
# allowed; anything else is rejected. Pins are declarations, never shell
# code, so the file is parsed, never sourced. The whole file is validated on
# every read — the contract must hold even for lines after the wanted key.
# A missing key is not an error (callers decide what absence means).
#
# Sourced only — defines functions, executes nothing.
# shellcheck shell=bash

# pins_discover <dir> — the pins file at or above <dir>. Empty output
# means "no pins file"; the caller decides what that means (a declaration
# check skips, a build refuses).
pins_discover() {
  local dir
  dir="$(cd "$1" 2>/dev/null && pwd)" || return 0
  [[ -n $dir ]] || return 0
  while :; do
    if [[ -f $dir/pins.toml ]]; then
      printf '%s' "$dir/pins.toml"
      return 0
    fi
    [[ -e $dir/.git || $dir == / ]] && return 0
    dir="$(dirname "$dir")"
  done
}

# pins_get <file> <key> [prefix] — read one KEY from a pins file.
# <prefix> is the prefix a failed read prints (by default the CLI's
# `[snails]`); an engine passes its own so every surface keeps the
# message style it documents.
pins_get() {
  local file="$1" want="$2" prefix="${3:-[snails]}" line key val result=""
  while IFS= read -r line || [[ -n $line ]]; do
    [[ $line =~ ^[[:space:]]*$ || $line =~ ^[[:space:]]*# ]] && continue
    if [[ $line =~ ^([A-Za-z_][A-Za-z0-9_]*)=\"([^\"]*)\"$ ]]; then
      key="${BASH_REMATCH[1]}"; val="${BASH_REMATCH[2]}"
    elif [[ $line =~ ^([A-Za-z_][A-Za-z0-9_]*)=([^[:space:]]+)$ ]]; then
      key="${BASH_REMATCH[1]}"; val="${BASH_REMATCH[2]}"
    else
      echo "$prefix $file: invalid pins line (want KEY=\"value\"): $line" >&2
      return 1
    fi
    [[ $key == "$want" ]] && result="$val"
  done < "$file"
  printf '%s' "$result"
  return 0
}

# pins_source <file> [prefix] — the declared build source: `pin` (vendor
# SNALS_REV) or `checkout` (vendor the core checkout's working tree).
# If absent, the source is `pin`: apps created before the source key existed
# keep the pin behavior. Any other value fails with a clear error.
pins_source() {
  local file="$1" prefix="${2:-[snails]}" source
  source="$(pins_get "$file" SNALS_SOURCE "$prefix")" || return 1
  [[ -n $source ]] || source="pin"
  case "$source" in
    pin|checkout) ;;
    *)
      echo "$prefix $file: SNALS_SOURCE must be \"pin\" or \"checkout\", got: $source" >&2
      return 1
      ;;
  esac
  printf '%s' "$source"
}
