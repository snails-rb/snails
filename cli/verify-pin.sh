#!/bin/bash
# Verify that SNALS_REV is a usable pin for this snails checkout.
#
# A pin is a DECLARATION ("this app vendors the core content at <rev>"),
# not a condition on this checkout. `bin/snails sync --pins` restores the
# core from <rev>, so the vendored bytes and the `sync --check --pins`
# reference both come from the pin — this working tree decides neither.
#
# Check: <rev> exists and every core path (runtime/ cli/ scaffold/ bin/
# plus a pins file) restores from it.
# Notice (stdout, never fails): this checkout's core content differs from
# <rev> — the counts, plus the core-touching commit subjects with
# --verbose, because a checkout that moved on must inform, not block.
#
# Usage: cli/verify-pin.sh <rev> [--verbose]
# Exit: 0=usable pin, 1=unknown rev / core paths not restorable.
set -euo pipefail

REV="${1:-}"
VERBOSE=0
if [[ ${2:-} == "--verbose" ]]; then
  VERBOSE=1
elif [[ -n ${2:-} ]]; then
  echo "usage: snails verify-pin <rev> [--verbose]" >&2
  exit 1
fi
if [[ $# -gt 2 ]]; then
  echo "usage: snails verify-pin <rev> [--verbose]" >&2
  exit 1
fi
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Core paths a usable pin must carry. The engine directory was renamed
# twice (script -> scripts -> cli), so a rev carries one name from that
# family; the pins file is pins.toml (the pre-2026-10-11 pins.conf is no
# longer a usable pin). The diff/log pathspecs list every generation (a
# pathspec that matches nothing is inert there); the restore check probes
# what the rev must carry today.
CORE_PATHS=(runtime cli scripts script scaffold bin pins.toml)

if [[ -z $REV ]]; then
  echo "usage: snails verify-pin <rev> [--verbose]" >&2
  exit 1
fi
if ! git -C "$ROOT" cat-file -e "${REV}^{commit}" 2>/dev/null; then
  echo "unknown SNALS_REV: $REV" >&2
  exit 1
fi
# The pin is only usable when sync can restore all of these paths from it.
RESTORE_PATHS=(runtime scaffold bin)
if git -C "$ROOT" cat-file -e "${REV}:cli" 2>/dev/null; then
  RESTORE_PATHS+=(cli)
elif git -C "$ROOT" cat-file -e "${REV}:scripts" 2>/dev/null; then
  RESTORE_PATHS+=(scripts)
else
  RESTORE_PATHS+=(script)
fi
if ! git -C "$ROOT" archive "$REV" -- "${RESTORE_PATHS[@]}" >/dev/null 2>&1 \
   || ! git -C "$ROOT" cat-file -e "${REV}:pins.toml" 2>/dev/null; then
  echo "SNALS_REV($REV) does not carry ${RESTORE_PATHS[*]} + a pins file — bump it to a rev that does" >&2
  exit 1
fi

# The checkout moving past the pin is information, not a failure: the pin
# decides what the app vendors, so a newer checkout never blocks it.
if ! git -C "$ROOT" diff --quiet "$REV" -- "${CORE_PATHS[@]}"; then
  pin_only=0
  checkout_only=0
  # A count failure downgrades to the plain "content differs" notice —
  # this branch must never become a block.
  read -r pin_only checkout_only < <(
    git -C "$ROOT" rev-list --left-right --count "$REV"...HEAD -- "${CORE_PATHS[@]}" 2>/dev/null
  ) || true

  why=""
  if ((checkout_only > 0)); then
    why="$checkout_only core commit(s) ahead of the pin"
  fi
  if ((pin_only > 0)); then
    [[ -n $why ]] && why="$why, "
    why="${why}${pin_only} core commit(s) behind the pin"
  fi
  if [[ -z $why ]]; then
    why="uncommitted changes in the core paths"
  fi

  printf 'notice: SNALS_REV(%s) content differs from this checkout (%s) — sync vendors from the rev, not the checkout\n' \
    "$REV" "$why"
  if ((VERBOSE)); then
    if ((checkout_only > 0)); then
      git -C "$ROOT" log --pretty=format:'  %h %s' -10 "$REV"..HEAD -- "${CORE_PATHS[@]}"
      printf '\n'
    elif ((pin_only > 0)); then
      git -C "$ROOT" log --pretty=format:'  %h %s' -10 HEAD.."$REV" -- "${CORE_PATHS[@]}"
      printf '\n'
    fi
  fi
fi
