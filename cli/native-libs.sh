# shellcheck shell=bash
# Link search paths for the native libraries a Snails app links.
#
# macOS keeps Homebrew's OpenSSL, jemalloc, and libpq outside the linker's
# default paths (/opt/homebrew/lib), and spin's own LIBRARY_PATH covers only
# the allocator. Every build engine exports these directories before it
# compiles, so bin/test, bin/dev, and bin/build-binary link on a host with
# only the packages the requirements docs list. pkg-config names the
# directories; the keg-only formulas (Intel's openssl@3, libpq) are found
# through the PKG_CONFIG_PATH the docs set. A library it does not know is
# skipped, and the link then fails exactly as it would have without this
# helper.
#
# Revert when spinel carries the directories itself (matz/spinel#11950).

# native_library_directories — the -L directories pkg-config reports for the
# libraries the app links. Empty when pkg-config is absent or knows none.
native_library_directories() {
  command -v pkg-config >/dev/null 2>&1 || return 0
  local library output token dirs=""
  for library in openssl jemalloc libpq; do
    output="$(pkg-config --libs-only-L "$library" 2>/dev/null)" || continue
    for token in $output; do
      case "$token" in
        -L?*) dirs+="${token#-L}:" ;;
      esac
    done
  done
  printf '%s' "${dirs%:}"
}

# export_native_library_paths — prepend the directories to LIBRARY_PATH for
# the compiler children this engine starts. A no-op when there is none.
export_native_library_paths() {
  local dirs
  dirs="$(native_library_directories)"
  [[ -n $dirs ]] || return 0
  export LIBRARY_PATH="$dirs${LIBRARY_PATH:+:$LIBRARY_PATH}"
}
