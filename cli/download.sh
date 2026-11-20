# Release-asset download helpers — shared by the CLI's distribution fetch
# (`bin/snails`) and the spinel toolchain resolver (`cli/toolchain.sh`).
#
# Sourced only. The release repositories are public; SNAILS_GITHUB_TOKEN is
# for a mirror that asks for authentication, not for the default GitHub
# release path. GitHub's release endpoint and API answer a transient 5xx or
# 429 under load; --retry covers those and connection failures, and a 404
# stays final. The timeouts keep an unreachable release host from hanging a
# sync that has a local cache or a source-build fallback to use.

snails_curl() {
  local url="$1"
  shift
  local retry=(--retry 3 --retry-delay 1 --retry-connrefused)
  if [[ -n ${SNAILS_GITHUB_TOKEN:-} ]]; then
    curl -fsSL "${retry[@]}" --connect-timeout 10 --max-time 300 \
      -H "Authorization: Bearer $SNAILS_GITHUB_TOKEN" "$@" "$url"
  else
    curl -fsSL "${retry[@]}" --connect-timeout 10 --max-time 300 "$@" "$url"
  fi
}

# snails_download <url> <output> — fetch one release asset.
snails_download() {
  local url="$1" out="$2"
  snails_curl "$url" -o "$out"
}

# snails_sha256_check <dir> <sidecar> — verify a sha256sum-format sidecar
# in <dir>. sha256sum is Linux; macOS has shasum.
snails_sha256_check() {
  local dir="$1" file="$2"
  if command -v sha256sum >/dev/null 2>&1; then
    (cd "$dir" && sha256sum -c "$file")
  else
    (cd "$dir" && shasum -a 256 -c "$file")
  fi
}
