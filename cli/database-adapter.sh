# DB adapter detection for the app-target engines: the single source for the
# rule.
#
# The database configuration is the app's own config/database.rb. The core
# boot chain requires `../config/database`, so that file must require exactly
# one adapter; the anchored require line is the adapter. Only anchored require
# lines are read, so a comment that mentions both backends does not confuse
# detection.
#
# The retired entry name (`config/db.rb`) is still read: an app that has not
# bumped its SNALS_REV yet runs the old scaffold (whose boot chain requires
# `config/db`), and an engine from the checkout must still recognize it.
# The new name wins when both exist; sync migrates the retired name in place.
#
# Sourced (never executed):
#   database_adapter_for <app_root> — print `sqlite` or `pg`; if the entry is
#                                  missing or ambiguous, print a message on
#                                  stderr and return 2.
# shellcheck shell=bash

DATABASE_ADAPTER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=vendor-dir.sh
source "$DATABASE_ADAPTER_DIR/vendor-dir.sh"

database_adapter_for() {
  local app_root="$1"
  local file="$app_root/config/database.rb" matches count pattern
  pattern="^require_relative \"\\.\\./($SNAILS_VENDOR_DIR|runtime)/database/(sqlite|postgresql)\""
  if [[ ! -f $file ]]; then
    file="$app_root/config/db.rb"
    pattern='^require_relative "\.\./runtime/db_(sqlite|postgresql)"'
  fi
  if [[ ! -f $file ]]; then
    echo "[snails] no config/database.rb (or the retired config/db.rb) under $app_root — the app's database configuration must require exactly one adapter; run: snails sync <app> to seed it (DB=pg for PostgreSQL, otherwise sqlite)" >&2
    return 2
  fi
  matches="$(grep -E "$pattern" "$file" || true)"
  count="$(printf '%s\n' "$matches" | grep -c . || true)"
  if [[ $count != 1 ]]; then
    echo "[snails] $file must require exactly one adapter ($SNAILS_VENDOR_DIR/database/sqlite or $SNAILS_VENDOR_DIR/database/postgresql; the legacy runtime/ paths are accepted until the app is migrated to the new names)" >&2
    return 2
  fi
  case "$matches" in
    *postgresql*) printf 'pg' ;;
    *) printf 'sqlite' ;;
  esac
}
