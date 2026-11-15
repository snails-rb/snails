#!/bin/bash
# Build and package one spinel toolchain release asset from source.
#
# The Linux assets come from the published bookworm image (the image is the
# ABI contract); this script is the macOS path, where no image exists. It
# can also build a Linux asset for a local check. The unit is the
# `make install` tree (`lib/spinel`: spin, spinel, builtins, lib, packages)
# because spinel resolves `builtins/` relative to its own location.
#
# Usage:
#   scripts/build-toolchain-asset.sh --rev <pin> --full <full-rev> \
#     --os <linux|darwin> --arch <amd64|arm64> --out <dir> [--prefix <dir>]
#
# Environment the caller owns:
#   CC and the C compiler; PKG_CONFIG_PATH/CPATH/LIBRARY_PATH for Homebrew
#   OpenSSL, libffi, libpq, jemalloc; MACOSX_DEPLOYMENT_TARGET for macOS.
#
# The release asset is `<out>/spinel-toolchain-<full>-<os>-<arch>.tar.gz` and
# a sha256 sidecar beside it. The smoke build is a hard gate: a toolchain
# missing openssl, ffi, sqlite3, pq, or jemalloc never reaches a release.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../cli/toolchain.sh
source "$ROOT/cli/toolchain.sh"

usage() {
  cat <<'USAGE'
usage: build-toolchain-asset.sh --rev <pin> --full <full-rev> \
  --os <linux|darwin> --arch <amd64|arm64> --out <dir> [--prefix <dir>]
USAGE
}

die() {
  echo "[build-toolchain-asset] $*" >&2
  exit 1
}

rev=""
full=""
os=""
arch=""
out=""
prefix=""
while (($#)); do
  case "$1" in
    --rev)    rev="${2:-}"; shift 2 ;;
    --full)   full="${2:-}"; shift 2 ;;
    --os)     os="${2:-}"; shift 2 ;;
    --arch)   arch="${2:-}"; shift 2 ;;
    --out)    out="${2:-}"; shift 2 ;;
    --prefix) prefix="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
[[ -n $rev ]] || die "--rev is required"
[[ -n $full ]] || die "--full is required"
[[ -n $out ]] || die "--out is required"
[[ $rev =~ ^[0-9a-f]{4,40}$ ]] || die "--rev is not a hexadecimal commit revision: $rev"
[[ $full =~ ^[0-9a-f]{40}$ ]] || die "--full is not a full 40-hex revision: $full"
[[ $full == "$rev"* ]] || die "--full ($full) does not start with --rev ($rev)"
case "$os" in
  linux|darwin) ;;
  *) die "--os must be linux or darwin: $os" ;;
esac
case "$arch" in
  amd64|arm64) ;;
  *) die "--arch must be amd64 or arm64: $arch" ;;
esac

for command in git make curl pkg-config; do
  command -v "$command" >/dev/null 2>&1 || die "$command is required to build spinel"
done
command -v cc >/dev/null 2>&1 || die "a C compiler (cc) is required to build spinel"

jobs="2"
if command -v nproc >/dev/null 2>&1; then
  jobs="$(nproc)"
elif command -v sysctl >/dev/null 2>&1; then
  jobs="$(sysctl -n hw.ncpu 2>/dev/null || echo 2)"
fi

work="$(mktemp -d)"
# shellcheck disable=SC2064
trap "rm -rf '$work'" EXIT
if [[ -z $prefix ]]; then
  prefix="$work/prefix"
fi
src="$work/spinel"
asset="$(spinel_toolchain_asset_name "$full" "$os" "$arch")"

# On macOS the smoke runs a linked pq; Homebrew's libpq is keg-only and
# dyld does not search its lib directory, so the runtime needs the fallback
# path too. The caller may set it; the standard formulas fill the gaps.
if [[ "$(uname -s)" == Darwin ]] && command -v brew >/dev/null 2>&1; then
  dyld_path=""
  for formula in openssl jemalloc libpq libffi; do
    dir="$(brew --prefix "$formula" 2>/dev/null)/lib"
    [[ -d $dir ]] && dyld_path+="${dir}:"
  done
  export DYLD_FALLBACK_LIBRARY_PATH="${dyld_path}${DYLD_FALLBACK_LIBRARY_PATH:-}"
fi

mkdir -p "$out"
rm -f "$out/$asset" "$out/$asset.sha256"

echo "[build-toolchain-asset] building spinel $rev from source" >&2
echo "[build-toolchain-asset] openssl $(pkg-config --modversion openssl 2>/dev/null || echo unknown)" >&2
git clone -q https://github.com/matz/spinel "$src"
git -C "$src" checkout -q "$rev"

# The table generators read prism/rbs; the versions match the published
# image so the generated tables do not depend on the runner's Ruby.
if command -v gem >/dev/null 2>&1; then
  gem install 'prism:1.9.0' 'rbs:4.0.1' --no-document >/dev/null 2>&1 || true
fi

(cd "$src" && make deps && make -j"$jobs" && make install PREFIX="$prefix")

unit="$prefix/lib/spinel"
[[ -x $unit/spin && -x $unit/spinel && -d $unit/builtins && -d $unit/lib && -d $unit/packages ]] \
  || die "unexpected spinel install layout: $unit"
mkdir -p "$unit/licenses"
cp "$src/LICENSE" "$unit/LICENSE"
if command -v gem >/dev/null 2>&1; then
  gem_dir="$(gem env gemdir 2>/dev/null || true)"
  [[ -f "$gem_dir/gems/prism-1.9.0/LICENSE.md" ]] &&
    cp "$gem_dir/gems/prism-1.9.0/LICENSE.md" "$unit/licenses/prism-LICENSE.md" || true
  [[ -f "$gem_dir/gems/rbs-4.0.1/BSDL" ]] &&
    cp "$gem_dir/gems/rbs-4.0.1/BSDL" "$unit/licenses/rbs-BSDL" || true
fi

# The pin check and the package smoke. Both are the same contracts the
# published image asserts; a source build that silently drops openssl or
# sqlite3 is worse than no asset at all.
for binary in spin spinel; do
  printed="$("$unit/$binary" --version 2>/dev/null | grep -oE '[0-9a-f]{7,40}' | head -n1 || true)"
  if [[ -z $printed || ( $printed != "$rev"* && "$rev" != "$printed"* ) ]]; then
    die "$binary reports '$printed', want pin $rev"
  fi
  echo "[build-toolchain-asset] $binary reports $printed" >&2
done

smoke="$work/smoke"
mkdir -p "$smoke"
"$unit/spinel" -e 'require "openssl"; require "ffi"; require "json"; puts "smoke ok"' \
  -o "$smoke/core" --strict-require >/dev/null
smoke_output="$( "$smoke/core" )"
[[ $smoke_output == "smoke ok" ]] || die "core smoke produced '$smoke_output'"

"$unit/spinel" -e 'require "sqlite3"; puts SQLite3::VERSION' \
  -o "$smoke/sqlite" --strict-require >/dev/null
sqlite_version="$( "$smoke/sqlite" )"
[[ -n $sqlite_version ]] || die "sqlite3 smoke produced no version"

"$unit/spinel" -e 'require "ffi"; module PqLinkSmoke; extend FFI::Library; ffi_lib "pq"; end; puts "pq ok"' \
  -o "$smoke/pq" --strict-require >/dev/null
smoke_output="$( "$smoke/pq" )"
[[ $smoke_output == "pq ok" ]] || die "pq link smoke produced '$smoke_output'"

# The spin project tool and the allocator are part of the unit too: a
# binary that compiles the core smoke but cannot link a program is not a
# usable toolchain.
mkdir -p "$smoke/app/bin"
cat > "$smoke/app/spin.toml" <<'TOML'
[package]
allocator = "jemalloc"
TOML
cat > "$smoke/app/bin/smoke.rb" <<'RUBY'
require "openssl"
require "ffi"
require "json"
require "sqlite3"
puts "spin smoke ok"
RUBY
(cd "$smoke/app" && PATH="$unit:$PATH" "$unit/spin" build >/dev/null)
smoke_output="$( PATH="$unit:$PATH" "$smoke/app/build/bin/smoke" )"
[[ $smoke_output == "spin smoke ok" ]] || die "spin build smoke produced '$smoke_output'"
echo "[build-toolchain-asset] smoke ok (sqlite3 $sqlite_version)" >&2

tar -czf "$out/$asset" -C "$unit" .
if command -v sha256sum >/dev/null 2>&1; then
  (cd "$out" && sha256sum "$asset" > "$asset.sha256")
else
  (cd "$out" && shasum -a 256 "$asset" > "$asset.sha256")
fi

echo "[build-toolchain-asset] wrote $out/$asset"
