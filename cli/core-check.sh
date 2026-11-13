# Decide whether the app's vendored core may be built.
#
# The pins file declares the build source: `SNALS_SOURCE="pin"` vendors
# SNALS_REV, `SNALS_SOURCE="checkout"` vendors the core checkout's working
# tree. Absence means "pin" (apps created before the key existed). The
# harness verifies exactly the declared source; it never guesses or falls
# back. A checkout source needs a CLI from a checkout; a distribution
# install has no working tree to verify.
#
# Sourced by cli/harness-test.sh and cli/harness-dev.sh; also exercised by
# scripts/test-cli.sh. Defines functions, executes nothing.

_core_check_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=pins.sh
source "$_core_check_dir/pins.sh"

# core_checkout_root <cli> — the development checkout that owns <cli>, or
# no output for an installed distribution. A linked worktree stores .git as
# a file, so -e covers both layouts.
core_checkout_root() {
  local cli="$1" root
  root="$(cd "$(dirname "$cli")/.." 2>/dev/null && pwd)" || return 0
  [[ -e "$root/.git" ]] || return 0
  printf '%s' "$root"
}

# core_check <cli> <app_root> — print the check's progress on stderr and
# return 0 when the vendored core matches its declared source, 1 otherwise.
# On success CORE_SOURCE is "pin" or "checkout"; the caller names the
# source in its build line.
CORE_SOURCE=""
core_check() {
  local cli="$1" app_root="$2" pins source report=""
  CORE_SOURCE=""
  pins="$(pins_discover "$app_root")"
  if [[ -n $pins ]]; then
    source="$(pins_source "$pins")" || return 1
  else
    source="pin"
  fi
  case "$source" in
    pin)
      if report="$("$cli" sync "$app_root" --check 2>&1)"; then
        [[ -z $report ]] || printf '%s\n' "$report" >&2
        CORE_SOURCE="pin"
        return 0
      fi
      ;;
    checkout)
      if [[ -z "$(core_checkout_root "$cli")" ]]; then
        echo "[snails] this app declares SNALS_SOURCE=\"checkout\" — run from the core checkout, or set SNALS_SOURCE=\"pin\"" >&2
        return 1
      fi
      if report="$("$cli" sync "$app_root" --check --from-checkout 2>&1)"; then
        [[ -z $report ]] || printf '%s\n' "$report" >&2
        CORE_SOURCE="checkout"
        return 0
      fi
      ;;
  esac
  [[ -z $report ]] || printf '%s\n' "$report" >&2
  return 1
}
