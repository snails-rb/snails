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
# shellcheck source=download.sh
source "$_toolchain_dir/download.sh"

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
    echo "[snails] git is required to build spinel ${pin} from source — install git, then retry" >&2
    return 1
  }
  work="$(mktemp -d)"
  if ! git clone -q https://github.com/matz/spinel "$work/src"; then
    rm -rf "$work"
    echo "[snails] could not clone https://github.com/matz/spinel — check network access to github.com, then retry" >&2
    return 1
  fi
  if ! git -C "$work/src" checkout -q "$pin"; then
    rm -rf "$work"
    echo "[snails] spinel has no commit ${pin} upstream — check the SPINEL_REV pin" >&2
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
    echo "[snails] unexpected spinel install layout: ${unit} (want spin, spinel, builtins/) — reinstall the pinned toolchain: snails sync" >&2
    return 1
  fi
  if ! spinel_toolchain_fresh "$unit" "$pin"; then
    rm -rf "$work"
    echo "[snails] the build at ${pin} reports a different revision than the pinned one — check the SPINEL_REV pin" >&2
    return 1
  fi
  if ! spinel_toolchain_store "$unit" "$cache"; then
    rm -rf "$work"
    return 1
  fi
  rm -rf "$work"
}

# spinel_host_os — the OS segment of the release asset name. Only the
# platforms that have published assets are recognized; anything else falls
# through to the source build.
spinel_host_os() {
  case "$(uname -s 2>/dev/null || true)" in
    Linux)  printf 'linux' ;;
    Darwin) printf 'darwin' ;;
    *)      return 1 ;;
  esac
}

# spinel_host_arch — the architecture segment of the release asset name.
# uname reports x86_64/aarch64 on Linux and arm64 on macOS; the assets use
# the OCI names amd64/arm64.
spinel_host_arch() {
  case "$(uname -m 2>/dev/null || true)" in
    x86_64|amd64)   printf 'amd64' ;;
    arm64|aarch64)  printf 'arm64' ;;
    *)              return 1 ;;
  esac
}

# spinel_host_is_musl — the published Linux assets are glibc builds, so a
# musl host (Alpine) must not download one. The platform is outside the
# support contract; the source build remains the only path.
spinel_host_is_musl() {
  [[ -f /etc/alpine-release ]] && return 0
  ldd --version 2>&1 | grep -qi musl
}

# spinel_toolchain_asset_name <full-rev> <os> <arch> — one naming rule for
# the resolver and the publishing workflow.
spinel_toolchain_asset_name() {
  printf 'spinel-toolchain-%s-%s-%s.tar.gz' "$1" "$2" "$3"
}

# spinel_toolchain_release_base — where the toolchain release assets live.
# The repositories are public; SNAILS_SPINEL_BASE_URL exists so a mirror or
# a test can serve the same layout (the same convention as the dist base).
spinel_toolchain_release_base() {
  printf '%s' "${SNAILS_SPINEL_BASE_URL:-https://github.com/snails-rb/snails/releases/download}"
}

# spinel_toolchain_commit_base — the upstream commit API used to expand an
# abbreviated pin. SNAILS_SPINEL_GIT_BASE_URL is the mirror/test override.
spinel_toolchain_commit_base() {
  printf '%s' "${SNAILS_SPINEL_GIT_BASE_URL:-https://api.github.com/repos/matz/spinel}"
}

# spinel_rev_full <pin> — the full 40-hex commit id of a pin. The release
# tag and asset name use the full form; a pins file may carry 7–9 chars.
# The commit API is the only reliable expansion (`git ls-remote` lists refs,
# not arbitrary commits), so the mapping is cached and a token is allowed
# for the API rate limit or a private mirror.
spinel_rev_full() {
  local pin="$1" base cache body full
  if [[ $pin =~ ^[0-9a-f]{40}$ ]]; then
    printf '%s' "$pin"
    return 0
  fi
  [[ $pin =~ ^[0-9a-f]{4,39}$ ]] || return 1
  base="${XDG_CACHE_HOME:-$HOME/.cache}/snails/spinel/commits"
  cache="$base/$pin"
  if [[ -f $cache ]]; then
    full="$(<"$cache")"
    [[ $full =~ ^[0-9a-f]{40}$ ]] && { printf '%s' "$full"; return 0; }
  fi
  body="$(snails_curl "$(spinel_toolchain_commit_base)/commits/$pin")" || return 1
  full="$(printf '%s' "$body" | sed -n 's/.*"sha":[[:space:]]*"\([0-9a-f]\{40\}\)".*/\1/p' | head -n1)"
  [[ $full =~ ^[0-9a-f]{40}$ ]] || return 1
  mkdir -p "$base" 2>/dev/null || true
  printf '%s\n' "$full" > "$cache" 2>/dev/null || true
  printf '%s' "$full"
}

# spinel_toolchain_download <pin> <cache> — fetch, verify, and store the
# published toolchain asset for this host. Returns 0 on success, 1 when the
# asset is unavailable (the caller may fall back to PATH or source), and 2
# when the asset is present but fails its integrity or revision contract
# (the caller must stop; a corrupt published artifact is not a cache miss).
spinel_toolchain_download() {
  local pin="$1" cache="$2" full os arch asset tag tmp
  full="$(spinel_rev_full "$pin")" || {
    echo "[snails] could not resolve the full revision for spinel ${pin} — falling back" >&2
    return 1
  }
  os="$(spinel_host_os)" || {
    echo "[snails] no prebuilt toolchain for spinel ${pin} on this OS — falling back" >&2
    return 1
  }
  arch="$(spinel_host_arch)" || {
    echo "[snails] no prebuilt toolchain for spinel ${pin} on this CPU — falling back" >&2
    return 1
  }
  if [[ $os == linux ]] && spinel_host_is_musl; then
    echo "[snails] the prebuilt toolchain for spinel ${pin} is glibc-only; Alpine/musl falls back to the source build" >&2
    return 1
  fi
  asset="$(spinel_toolchain_asset_name "$full" "$os" "$arch")"
  tag="spinel-rev-$full"
  tmp="${cache}.download.$$"
  rm -rf "$tmp"
  mkdir -p "$tmp"
  if ! snails_download "$(spinel_toolchain_release_base)/$tag/$asset" "$tmp/$asset"; then
    rm -rf "$tmp"
    echo "[snails] no prebuilt toolchain asset for spinel ${full} ${os}-${arch} — falling back" >&2
    return 1
  fi
  if ! snails_download "$(spinel_toolchain_release_base)/$tag/$asset.sha256" "$tmp/$asset.sha256"; then
    rm -rf "$tmp"
    echo "[snails] the checksum for the spinel ${full} ${os}-${arch} toolchain is missing — falling back" >&2
    return 1
  fi
  if ! snails_sha256_check "$tmp" "$asset.sha256" >/dev/null; then
    rm -rf "$tmp"
    echo "[snails] the spinel ${full} ${os}-${arch} toolchain failed its sha256 check — refusing the download" >&2
    return 2
  fi
  if ! tar -xzf "$tmp/$asset" -C "$tmp" 2>/dev/null; then
    rm -rf "$tmp"
    echo "[snails] the spinel ${full} ${os}-${arch} toolchain is not a valid tar archive — refusing the download" >&2
    return 2
  fi
  rm -f "$tmp/$asset" "$tmp/$asset.sha256"
  if [[ ! -x $tmp/spin || ! -x $tmp/spinel || ! -d $tmp/builtins ||
        ! -d $tmp/lib || ! -d $tmp/packages ]]; then
    rm -rf "$tmp"
    echo "[snails] the spinel ${full} ${os}-${arch} toolchain has an unexpected layout — refusing the download" >&2
    return 2
  fi
  if ! spinel_toolchain_fresh "$tmp" "$pin"; then
    rm -rf "$tmp"
    echo "[snails] the spinel ${full} ${os}-${arch} toolchain reports a different revision — refusing the download" >&2
    return 2
  fi
  if ! spinel_toolchain_store "$tmp" "$cache"; then
    rm -rf "$tmp"
    return 1
  fi
  rm -rf "$tmp"
  return 0
}

# spinel_toolchain_ensure <pins> [<verbose>] — materialize the pinned
# toolchain into the project copy: an existing cache entry first (a
# differently spelled pin of the same revision reuses one copy), then the
# published asset for this host, then a PATH install already at the pin, then
# a source build. Each source is version-checked before it is copied. The
# destination path is internal, so only --verbose prints it.
spinel_toolchain_ensure() {
  local pins="$1" verbose="${2:-0}" pin dest cache src reused detail="" download_rc=0
  pin="$(spinel_pins_rev "$pins")" || return 1
  dest="$(spinel_toolchain_dir "$pins")"
  spinel_toolchain_fresh "$dest" "$pin" && return 0
  ((verbose)) && detail=" -> ${dest}"

  cache="$(spinel_toolchain_cache "$pin")"
  if ! spinel_toolchain_fresh "$cache" "$pin"; then
    reused="$(spinel_toolchain_cache_lookup "$pin")"
    [[ -n $reused ]] && cache="$reused"
  fi
  if spinel_toolchain_fresh "$cache" "$pin"; then
    spinel_toolchain_store "$cache" "$dest"
    echo "[snails] spinel ${pin} ready (cache)${detail}" >&2
    return 0
  fi

  if spinel_toolchain_download "$pin" "$cache"; then
    if spinel_toolchain_store "$cache" "$dest"; then
      echo "[snails] spinel ${pin} ready (download)${detail}" >&2
      return 0
    fi
  else
    download_rc=$?
    # 2 is an integrity failure, not a cache miss: the published artifact
    # is corrupt or for another revision, and rebuilding from source would
    # hide that instead of surfacing it.
    ((download_rc == 2)) && return 1
  fi

  src="$(spinel_toolchain_path_source "$pin")"
  if [[ -n $src ]]; then
    spinel_toolchain_store "$src" "$cache" 2>/dev/null || true
    spinel_toolchain_store "$src" "$dest"
    echo "[snails] spinel ${pin} ready (PATH install)${detail}" >&2
    return 0
  fi

  echo "[snails] no cached, downloaded, or PATH toolchain for spinel ${pin} — building from source (once per rev)" >&2
  spinel_toolchain_build "$pin" "$cache" || return 1
  spinel_toolchain_store "$cache" "$dest"
  echo "[snails] spinel ${pin} ready (source build)${detail}" >&2
}

# spinel_toolchain_check <pins> [<app_root>] [<verbose>] — the `--check` view:
# report only, never write. A missing copy and a stale copy fail the same way:
# the gate must not pass while builds would run an unpinned toolchain. The
# repair line names the app root (the pins file may live outside it).
spinel_toolchain_check() {
  local pins="$1" app_root="${2:-}" verbose="${3:-0}" pin dest sync_arg sync_command
  [[ -n $app_root ]] || app_root="$(dirname "$pins")"
  pin="$(spinel_pins_rev "$pins")" || return 1
  dest="$(spinel_toolchain_dir "$pins")"
  if spinel_toolchain_fresh "$dest" "$pin"; then
    if ((verbose)); then
      echo "[snails] ${dest} in sync (spinel ${pin})"
    else
      echo "[snails] spinel toolchain in sync (${pin})"
    fi
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
        echo "[snails] snails sync failed while materializing the toolchain — fix the error above, then retry" >&2
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
      echo "[snails] the spinel ${pin} toolchain is still missing after sync — fix the sync error above" >&2
      return 1
    fi
  fi
  export PATH="${dest}:${PATH}"
}
