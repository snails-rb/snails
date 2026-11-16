# shellcheck shell=bash
# Native library search paths for the libraries a Snails app links.
#
# macOS keeps Homebrew's OpenSSL, jemalloc, and libpq outside the linker's
# default paths (/opt/homebrew/lib), and the keg-only formulas keep their
# .pc files outside pkg-config's default path. Every build engine resolves
# both here before it compiles, so bin/test, bin/dev, and bin/build-binary
# link on a host with only the packages the requirements docs list — no
# export in the developer's shell.
#
# The formulas are read through `brew --prefix`, which follows aliases:
# `openssl` is whatever `brew install openssl` installed, `libpq` is the
# client-only package, and `postgresql` (server first) carries libpq under
# lib/postgresql. A formula that is not installed is skipped. Exporting
# PKG_CONFIG_PATH also gives spinel's own `pkg-config --cflags` the keg-only
# headers, so the app build needs nothing else.
#
# Revert when spinel carries the directories itself (matz/spinel#11950) and
# the app declares libpq (snails-rb/snails#75).

# export_native_library_paths — add the Homebrew pkg-config directories to
# PKG_CONFIG_PATH, then the libraries' -L directories to LIBRARY_PATH. A
# no-op on a host without Homebrew.
export_native_library_paths() {
  command -v brew >/dev/null 2>&1 || return 0
  local formula prefix dir pkgconfig="" output token dirs=""
  for formula in openssl jemalloc libpq postgresql; do
    prefix="$(brew --prefix "$formula" 2>/dev/null)" || continue
    for dir in "$prefix/lib/pkgconfig" "$prefix/lib/postgresql/pkgconfig"; do
      [[ -d $dir ]] && pkgconfig+="$dir:"
    done
  done
  [[ -n $pkgconfig ]] || return 0
  export PKG_CONFIG_PATH="${pkgconfig%:}${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
  command -v pkg-config >/dev/null 2>&1 || return 0
  for formula in openssl jemalloc libpq; do
    output="$(pkg-config --libs-only-L "$formula" 2>/dev/null)" || continue
    for token in $output; do
      case "$token" in
        -L?*) dirs+="${token#-L}:" ;;
      esac
    done
  done
  [[ -n $dirs ]] || return 0
  export LIBRARY_PATH="$dirs${LIBRARY_PATH:+:$LIBRARY_PATH}"
}
