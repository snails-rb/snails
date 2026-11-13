# spinel toolchain resolver — pins.toml's SPINEL_REV decides which spinel
# build an app tree may compile with; this file turns that pin into the
# toolchain the build uses.
#
# Two audiences, one implementation:
#   - the harness engines (cli/harness-test.sh, cli/harness-dev.sh)
#     source it and call spinel_toolchain_env, which puts the pinned
#     toolchain on PATH — materializing it through the snails CLI when the
#     project copy is missing or stale.
#   - bin/snails sources it from the engine tree and calls
#     spinel_toolchain_ensure / spinel_toolchain_check to materialize or
#     verify that same copy.
#
# Layout: <pins file dir>/.spinel/toolchain/{spin,spinel,builtins,lib,packages}
# — the toolchain moves as a unit because spinel resolves builtins/ relative to
# its own location. Backing store: $XDG_CACHE_HOME/snails/spinel/<rev>/toolchain
# (default ~/.cache). The project copy is gitignored: state, never source.
#
# Sourced only — defines functions, executes nothing.

_toolchain_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=app-root.sh
source "$_toolchain_dir/app-root.sh"
# shellcheck source=pins.sh
source "$_toolchain_dir/pins.sh"

# spinel_snails_cli — locate the snails CLI without hardcoding a local path:
# the CLI that set SNAILS_CLI (the one running the harness engine) is
# authoritative; otherwise SNAILS_DIR (the checkout), otherwise `snails` on
# PATH. Callers print their own guidance when this comes back empty.
spinel_snails_cli() {
  if [[ -n ${SNAILS_CLI:-} ]]; then
    printf '%s\n' "$SNAILS_CLI"
  elif [[ -n ${SNAILS_DIR:-} ]]; then
    printf '%s\n' "$SNAILS_DIR/bin/snails"
  else
    command -v snails 2>/dev/null || true
  fi
}

# spinel_pins_rev <pins> — the SPINEL_REV declaration, validated at the
# entry point. The rev becomes part of a filesystem path (cache layout),
# so anything other than a hexadecimal commit revision fails here instead of
# being used in a path. A missing value fails too: a pins file that exists
# but never declares the toolchain revision is the gap this check closes.
# The read uses the shared pins parser (cli/pins.sh) with this engine's
# message prefix.
spinel_pins_rev() {
  local pins="$1" pin
  pin="$(pins_get "$pins" SPINEL_REV "[snails]")" || return 1
  if [[ -z $pin ]]; then
    echo "[snails] $pins has no SPINEL_REV — the toolchain pin is part of the pins contract" >&2
    return 1
  fi
  if [[ ! $pin =~ ^[0-9a-f]{4,40}$ ]]; then
    echo "[snails] $pins: SPINEL_REV is not a hex commit rev: $pin" >&2
    return 1
  fi
  printf '%s' "$pin"
}

# spinel_toolchain_dir <pins> — the project copy lives next to the pins
# file that declares the rev (the repo root in every real layout).
spinel_toolchain_dir() {
  printf '%s' "$(dirname "$1")/.spinel/toolchain"
}

# spinel_toolchain_cache <rev> — the per-revision backing store: it
# survives a project rebuild and is shared by checkouts on the same
# machine.
spinel_toolchain_cache() {
  printf '%s' "${XDG_CACHE_HOME:-$HOME/.cache}/snails/spinel/$1/toolchain"
}

# spinel_toolchain_cache_lookup <pin> — one existing cache entry that is
# fresh for the pin, if any. Pin spellings of different lengths (a short
# pinned rev vs the full hash) must share one copy: the cache key is the
# written value, so without this lookup each spelling would materialize
# its own duplicate. Prints nothing on a miss.
spinel_toolchain_cache_lookup() {
  local pin="$1" base dir
  base="${XDG_CACHE_HOME:-$HOME/.cache}/snails/spinel"
  [[ -d $base ]] || return 0
  for dir in "$base"/*/toolchain; do
    if spinel_toolchain_fresh "$dir" "$pin"; then
      printf '%s' "$dir"
      return 0
    fi
  done
}

# spinel_toolchain_rev <binary> — the commit revision `--version` reports,
# or empty when the output has none (unverifiable is never "fresh").
spinel_toolchain_rev() {
  "$1" --version 2>/dev/null | grep -oE '[0-9a-f]{7,40}' | head -n1 || true
}

# spinel_rev_matches <printed> <pin> — one is a prefix of the other:
# pins carry 7-9 chars while `--version` prints 8, so neither side is
# the canonical length.
spinel_rev_matches() {
  local printed="$1" pin="$2"
  [[ -n $printed && -n $pin ]] || return 1
  [[ $printed == "$pin"* || $pin == "$printed"* ]]
}

# spinel_toolchain_fresh <dir> <pin> — both binaries exist and both
# report the pinned rev.
spinel_toolchain_fresh() {
  local dir="$1" pin="$2"
  [[ -x $dir/spin && -x $dir/spinel ]] || return 1
  spinel_rev_matches "$(spinel_toolchain_rev "$dir/spin")" "$pin" || return 1
  spinel_rev_matches "$(spinel_toolchain_rev "$dir/spinel")" "$pin" || return 1
}

# spinel_path_matches <pin> — the PATH install itself reports the pin
# (the fallback a CLI-less synced app may rely on).
spinel_path_matches() {
  local pin="$1" sw sp
  sw="$(command -v spin 2>/dev/null)" || return 1
  sp="$(command -v spinel 2>/dev/null)" || return 1
  spinel_rev_matches "$(spinel_toolchain_rev "$sw")" "$pin" || return 1
  spinel_rev_matches "$(spinel_toolchain_rev "$sp")" "$pin"
}

# spinel_realpath <path> — physical path (symlink-following); realpath is
# not everywhere, python3 is the fallback.
spinel_realpath() {
  if command -v realpath >/dev/null 2>&1; then
    realpath "$1"
  else
    python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$1"
  fi
}

# spinel_toolchain_path_source <pin> — a directory holding a complete
# toolchain whose binaries report the pin (the unit `make install` lays out).
# Prints nothing when no PATH install qualifies: a half-installed or
# unpinned layout must not become the materialization source.
spinel_toolchain_path_source() {
  local pin="$1" sp dir
  sp="$(command -v spinel 2>/dev/null)" || return 0
  dir="$(dirname "$(spinel_realpath "$sp")")"
  # The layout check comes before any `--version` run. A PATH entry can be
  # a launcher rather than a toolchain — the snails shim calls `snails
  # exec`, which resolves this same toolchain — so running it to read a
  # version can re-enter this resolver. A complete toolchain directory is
  # the contract; anything else is rejected without being executed.
  [[ -x $dir/spin && -d $dir/builtins && -d $dir/lib && -d $dir/packages &&
     ! -e $dir/.git ]] || return 0
  spinel_rev_matches "$(spinel_toolchain_rev "$dir/spin")" "$pin" || return 0
  spinel_rev_matches "$(spinel_toolchain_rev "$dir/spinel")" "$pin" || return 0
  printf '%s' "$dir"
}

# spinel_toolchain_store <src> <dest> — copy the toolchain into place
# without ever leaving a half-written destination (the cache is a shared
# tree).
spinel_toolchain_store() {
  local src="$1" dest="$2" tmp
  mkdir -p "$(dirname "$dest")"
  tmp="${dest}.tmp.$$"
  rm -rf "$tmp"
  cp -a "$src" "$tmp"
  rm -rf "$dest"
  mv "$tmp" "$dest"
}

# spinel_ncpu — parallelism for the source build; nproc is Linux-only.
spinel_ncpu() {
  if command -v nproc >/dev/null 2>&1; then
    nproc
  elif command -v sysctl >/dev/null 2>&1; then
    sysctl -n hw.ncpu 2>/dev/null || echo 2
  else
    echo 2
  fi
}

# spinel_toolchain_build <pin> <cache> — last resort: clone spinel at the
# pin, build it, and store the installed toolchain in the cache. A compiler
# toolchain is a real dependency, so every failure is reported — a silent
# skip here would put an unpinned build back on PATH.
spinel_toolchain_build() {
  local pin="$1" cache="$2" work unit
  command -v git >/dev/null 2>&1 || {
    echo "[snails] git is required to build spinel ${pin} from source" >&2
    return 1
  }
  work="$(mktemp -d)"
  if ! git clone -q https://github.com/matz/spinel "$work/src"; then
    rm -rf "$work"
    echo "[snails] could not clone https://github.com/matz/spinel" >&2
    return 1
  fi
  if ! git -C "$work/src" checkout -q "$pin"; then
    rm -rf "$work"
    echo "[snails] spinel has no commit ${pin} upstream" >&2
    return 1
  fi
  if ! (cd "$work/src" && make deps && make -j"$(spinel_ncpu)" &&
        make install PREFIX="$work/prefix"); then
    rm -rf "$work"
    echo "[snails] building spinel ${pin} failed. Build it by hand, then sync again:" >&2
    echo "[snails]   git clone https://github.com/matz/spinel && cd spinel && git checkout ${pin} && make deps && make -j && make install PREFIX=<scratch-dir>" >&2
    echo "[snails] the retry accepts a PATH install that reports ${pin} — put <scratch-dir>/bin on PATH for that run" >&2
    return 1
  fi
  unit="$work/prefix/lib/spinel"
  if [[ ! -x $unit/spin || ! -x $unit/spinel || ! -d $unit/builtins ]]; then
    rm -rf "$work"
    echo "[snails] unexpected spinel install layout: ${unit} (want spin, spinel, builtins/)" >&2
    return 1
  fi
  if ! spinel_toolchain_fresh "$unit" "$pin"; then
    rm -rf "$work"
    echo "[snails] the build at ${pin} reports a different revision than the pinned one" >&2
    return 1
  fi
  if ! spinel_toolchain_store "$unit" "$cache"; then
    rm -rf "$work"
    return 1
  fi
  rm -rf "$work"
}

# spinel_toolchain_ensure <pins> — materialize the pinned toolchain into
# the project copy: an existing cache entry first (a differently spelled
# pin of the same revision reuses one copy), then a PATH install already at
# the pin, then a source build. Each source is version-checked before it is
# copied.
spinel_toolchain_ensure() {
  local pins="$1" pin dest cache src reused
  pin="$(spinel_pins_rev "$pins")" || return 1
  dest="$(spinel_toolchain_dir "$pins")"
  spinel_toolchain_fresh "$dest" "$pin" && return 0

  cache="$(spinel_toolchain_cache "$pin")"
  if ! spinel_toolchain_fresh "$cache" "$pin"; then
    reused="$(spinel_toolchain_cache_lookup "$pin")"
    [[ -n $reused ]] && cache="$reused"
  fi
  if spinel_toolchain_fresh "$cache" "$pin"; then
    spinel_toolchain_store "$cache" "$dest"
    echo "[snails] spinel ${pin} -> ${dest} (cache)" >&2
    return 0
  fi

  src="$(spinel_toolchain_path_source "$pin")"
  if [[ -n $src ]]; then
    spinel_toolchain_store "$src" "$cache" 2>/dev/null || true
    spinel_toolchain_store "$src" "$dest"
    echo "[snails] spinel ${pin} -> ${dest} (PATH install)" >&2
    return 0
  fi

  echo "[snails] no cached or PATH toolchain for spinel ${pin} — building from source (once per rev)" >&2
  spinel_toolchain_build "$pin" "$cache" || return 1
  spinel_toolchain_store "$cache" "$dest"
  echo "[snails] spinel ${pin} -> ${dest} (source build)" >&2
}

# spinel_toolchain_check <pins> [<app_root>] — the `--check` view: report
# only, never write. A missing copy and a stale copy fail the same way: the
# gate must not pass while builds would run an unpinned toolchain. The repair
# line names the app root (the pins file may live outside it).
spinel_toolchain_check() {
  local pins="$1" app_root="${2:-}" pin dest sync_arg sync_command
  [[ -n $app_root ]] || app_root="$(dirname "$pins")"
  pin="$(spinel_pins_rev "$pins")" || return 1
  dest="$(spinel_toolchain_dir "$pins")"
  if spinel_toolchain_fresh "$dest" "$pin"; then
    echo "[snails] ${dest} in sync (spinel ${pin})"
    return 0
  fi
  sync_arg="$(app_root_argument "$app_root")"
  sync_command="snails sync"
  [[ -n $sync_arg ]] && sync_command+=" $(shell_quote "$sync_arg")"
  echo "[snails] the pinned spinel toolchain (${pin}) is missing or stale — run: $sync_command to materialize it" >&2
  return 1
}

# spinel_toolchain_env <spin_root> — put the pinned toolchain on PATH.
# Contract: a fresh project copy never touches the CLI (a synced app needs
# no CLI); a miss goes through `snails sync`. Without
# a CLI, the PATH install is accepted only while it reports the pin — an
# unpinned PATH never becomes the build silently.
spinel_toolchain_env() {
  local root="$1" pins pin dest cli
  pins="$(pins_discover "$root")"
  if [[ -z $pins ]]; then
    echo "[snails] no pins file above ${root} — SPINEL_REV not enforced (PATH used as-is)" >&2
    return 0
  fi
  pin="$(spinel_pins_rev "$pins")" || return 1
  dest="$(spinel_toolchain_dir "$pins")"

  if ! spinel_toolchain_fresh "$dest" "$pin"; then
    cli="$(spinel_snails_cli)"
    if [[ -n $cli && -x $cli ]]; then
      if ! "$cli" sync "$root"; then
        echo "[snails] syncing the spinel toolchain via ${cli} failed" >&2
        return 1
      fi
    elif ! spinel_path_matches "$pin"; then
      echo "[snails] the project toolchain for spinel ${pin} is missing and no snails CLI is available." >&2
      echo "[snails] set SNAILS_DIR to the snails checkout (or put snails on PATH) so sync can materialize it." >&2
      return 1
    fi
    if ! spinel_toolchain_fresh "$dest" "$pin"; then
      if spinel_path_matches "$pin"; then
        echo "[snails] no project toolchain yet — using the PATH install (it reports spinel ${pin})" >&2
        return 0
      fi
      echo "[snails] toolchain for spinel ${pin} is still missing after sync: ${dest}" >&2
      return 1
    fi
  fi
  export PATH="${dest}:${PATH}"
}
