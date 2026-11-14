#!/bin/bash
# Shared-runtime vendor: copy the snails core into an app tree's snails-core/.
#
# The boot entry (snails-core/boot.rb) and the all profile
# (snails-core/boot/all.rb) ship inside snails-core/; the app owns
# config/boot.rb, the one-line profile selection the entry requires. An app
# tree must not carry a top-level boot.rb. A tree that still has one is
# refused before anything is written — its entry must move to the core boot
# first.
#
# Progress is printed on stderr; a plain run writes no stdout report (the
# CLI's `synced` line is the result). --verbose adds internal paths and
# absolute app paths; the default progress stays app-relative.
#
# Usage: cli/sync-runtime.sh <app_root> [--verbose]
#   <app_root>    the app tree that owns snails-core/ (e.g. src,
#                 apps/demo). <app_root>/snails-core is replaced
#                 wholesale (existing files are deleted).
set -euo pipefail

ENGINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SNAILS_ROOT="$(cd "$ENGINE_DIR/.." && pwd)"
# shellcheck source=vendor-dir.sh
source "$ENGINE_DIR/vendor-dir.sh"
CORE="$SNAILS_ROOT/runtime"

APP_ROOT=""
verbose=0
while (($#)); do
  case "$1" in
    --verbose) verbose=1; shift ;;
    -*) echo "usage: snails sync <app_root> [--verbose]" >&2; exit 1 ;;
    *) APP_ROOT="$1"; shift ;;
  esac
done

[[ -n $APP_ROOT ]] || { echo "usage: snails sync <app_root> [--verbose]" >&2; exit 1; }
[[ -d $APP_ROOT ]] || { echo "[snails] no such app root: $APP_ROOT — pass the directory that holds config/database.rb" >&2; exit 1; }
[[ -d $CORE ]] || { echo "[snails] the installed CLI is missing its runtime core — reinstall or upgrade snails" >&2; exit 1; }

# Progress lines name app-relative paths by default; absolute paths and the
# vendor directory name are internal, so only --verbose prints them.
created_from_scaffold() { # <path>
  local path="$1" rel="${1#"$APP_ROOT"/}"
  [[ -d $path ]] && rel+="/"
  if ((verbose)); then
    echo "[snails] created $path from the scaffold" >&2
  else
    echo "[snails] created $rel from the scaffold" >&2
  fi
}

# The app-level boot.rb is retired: the entry is <vendored core>/boot.rb and
# the selected profile lives in the app-owned config/boot.rb, which the copy
# below carries. Refuse before writing, so an existing app is not left
# half-migrated (main.rb would still require a file that no longer exists).
if [[ -f "$APP_ROOT/boot.rb" ]]; then
  echo "[snails] boot.rb is retired — replace main.rb with the current scaffold entry (a fresh 'snails new' app shows it), delete boot.rb, then rerun sync" >&2
  exit 1
fi

DST="$APP_ROOT/$SNAILS_VENDOR_DIR"

# Stamp the framework version metadata into the vendored copy. A
# distribution artifact already carries the published values; a checkout
# sync passes the resolved revision through SNAILS_VERSION/SNAILS_REV, so
# the binary reports the revision it was built from. An old core without
# the file predates the feature and is left untouched.
stamp_version() {
  local file="$DST/snails/version.rb" version="${SNAILS_VERSION:-}" rev="${SNAILS_REV:-}"
  if [[ ! -f $file ]]; then
    if ((verbose)); then
      echo "[snails] core has no $SNAILS_VENDOR_DIR/snails/version.rb — version metadata skipped" >&2
    fi
    return 0
  fi
  [[ -n $version && -n $rev ]] || return 0
  awk -v version="$version" -v rev="$rev" '
    /^[[:space:]]*VERSION = / { print "  VERSION = \"" version "\""; next }
    /^[[:space:]]*REV = /     { print "  REV = \"" rev "\""; next }
    { print }
  ' "$file" > "$file.stamp"
  mv "$file.stamp" "$file"
  if ! grep -Fqx "  VERSION = \"$version\"" "$file" ||
     ! grep -Fqx "  REV = \"$rev\"" "$file"; then
    echo "[snails] could not write version metadata to $file — the vendored core has an unexpected layout; reinstall or upgrade the CLI, then rerun sync" >&2
    exit 1
  fi
}

# Replacing the core wholesale is correct for a real change, but a no-op
# sync should not rewrite the whole tree or print copy progress. Compare
# first: the version metadata is stamped separately, so a stamp-only
# difference is not a core change.
core_changed=0
core_files=0
stamp_needed=0
if [[ ! -d $DST ]]; then
  core_changed=1
else
  core_diff="$(diff -rq "$CORE" "$DST" 2>/dev/null || true)"
  if [[ -n $core_diff && -n "$(printf '%s\n' "$core_diff" | grep -v '/snails/version.rb')" ]]; then
    core_changed=1
  fi
fi
if [[ -n ${SNAILS_VERSION:-} && -n ${SNAILS_REV:-} && -f $DST/snails/version.rb ]]; then
  if ! grep -Fqx "  VERSION = \"$SNAILS_VERSION\"" "$DST/snails/version.rb" ||
     ! grep -Fqx "  REV = \"$SNAILS_REV\"" "$DST/snails/version.rb"; then
    stamp_needed=1
  fi
fi
if ((core_changed)); then
  rm -rf "$DST"
  cp -R "$CORE" "$DST"
  stamp_version
  core_files="$(find "$DST" -type f | wc -l)"
  if ((verbose)); then
    echo "[snails] core -> $DST ($core_files files)" >&2
  else
    echo "[snails] core synced ($core_files files)" >&2
  fi
elif ((stamp_needed)); then
  stamp_version
fi

# DB adapter: the app owns the choice in config/database.rb (the core boot
# chain requires `config/database`), so the vendored core carries both
# backends with no such file and stays byte-identical across adapters.

# App tree: the gen/* require-all files, config/application.rb,
# config/environment.rb, and the config/database.rb configuration (all
# required by the core boot chain) are core defaults, so missing files are
# created from the scaffold seed (created once; contents are app-owned
# afterwards, and sync never rewrites them). The retired configuration name
# `config/db.rb` is migrated here (below). Then verify the scaffold contract
# (canonical byte match + GET /up + single definition — compare only, exit 1
# on violation).
# Runtime-only staging trees (no config/ and no app/, e.g. --check) have
# no app contract and are skipped.
if [[ -d $APP_ROOT/config || -d $APP_ROOT/app ]]; then
  for name in lib controllers helpers mailers models model_columns forms jobs services route_helpers; do
    dst="$APP_ROOT/gen/$name.rb"
    if [[ ! -f $dst ]]; then
      mkdir -p "$APP_ROOT/gen"
      cp "$SNAILS_ROOT/scaffold/seed/gen/$name.rb" "$dst"
      created_from_scaffold "$dst"
    fi
  done

  # The app load list — seeded once like config/application.rb. It requires
  # the generated gen/*.rb lists, and the boot chain requires this file only.
  dst="$APP_ROOT/config/codegen.rb"
  if [[ ! -f $dst ]]; then
    mkdir -p "$APP_ROOT/config"
    cp "$SNAILS_ROOT/scaffold/seed/config/codegen.rb" "$dst"
    created_from_scaffold "$dst"
  fi

  # The app config reopen the core boot chain requires — seeded once
  # like gen/*: the values stay app-owned (core-default placeholders).
  dst="$APP_ROOT/config/application.rb"
  if [[ ! -f $dst ]]; then
    mkdir -p "$APP_ROOT/config"
    cp "$SNAILS_ROOT/scaffold/seed/config/application.rb" "$dst"
    created_from_scaffold "$dst"
  fi

  # The app-owned boot profile the vendored boot entry requires — seeded
  # once. `all` is the only profile today; a later profile is an app edit
  # to this file, not a sync rewrite.
  dst="$APP_ROOT/config/boot.rb"
  if [[ ! -f $dst ]]; then
    mkdir -p "$APP_ROOT/config"
    cp "$SNAILS_ROOT/scaffold/seed/config/boot.rb" "$dst"
    created_from_scaffold "$dst"
  fi

  # The app environment the boot chain's last require names — seeded once
  # from the project template the same way (the boot-settings block is the
  # core default; the file is app-owned afterwards).
  dst="$APP_ROOT/config/environment.rb"
  if [[ ! -f $dst ]]; then
    mkdir -p "$APP_ROOT/config"
    cp "$SNAILS_ROOT/scaffold/new/config/environment.rb" "$dst"
    created_from_scaffold "$dst"
  fi

  # The database configuration the core boot chain requires. The retired name
  # `config/db.rb` is migrated in place: the anchored backend require line
  # IS the adapter declaration, so the adapter is read off it (never guessed)
  # and only that line is rewritten — the rest of the app-owned file is
  # preserved. Anything else fails with an error: a file with neither
  # anchored require, or a tree with both names, must not build (the core
  # boot chain requires exactly `config/database`).
  legacy="$APP_ROOT/config/db.rb"
  dst="$APP_ROOT/config/database.rb"
  if [[ -f $legacy && -f $dst ]]; then
    echo "[snails] both config/db.rb (retired) and config/database.rb exist — remove the retired file" >&2
    exit 1
  fi
  if [[ -f $legacy ]]; then
    matches="$(grep -E '^require_relative "\.\./runtime/db_(sqlite|postgresql)"$' "$legacy" || true)"
    count="$(printf '%s\n' "$matches" | grep -c . || true)"
    if [[ $count != 1 ]]; then
      echo "[snails] $legacy: the retired database configuration must carry exactly one anchored backend require (runtime/db_sqlite or runtime/db_postgresql)" >&2
      exit 1
    fi
    case "$matches" in
      *db_postgresql*) backend="postgresql" ;;
      *)               backend="sqlite" ;;
    esac
    old_line="$(printf '%s' "$matches")"
    new_line="require_relative \"../$SNAILS_VENDOR_DIR/database/$backend\""
    content=""
    while IFS= read -r line || [[ -n $line ]]; do
      if [[ $line == "$old_line" ]]; then
        line="$new_line"
      fi
      content="$content$line"$'\n'
    done < "$legacy"
    printf '%s' "$content" > "$dst"
    rm -f "$legacy"
    echo "[snails] config/db.rb migrated to config/database.rb (adapter: $backend) — comments in this app-owned file may still name the retired paths; review them" >&2
  fi

  # The database configuration itself: seeded once from the scaffold/new
  # template with the adapter spliced in. The retired DB environment
  # variable (the pins DB= declaration) names the adapter, so an existing pg
  # app keeps it; without it the core
  # default is sqlite. App-owned from then on: sync never rewrites it.
  if [[ ! -f $dst ]]; then
    case "${DB:-sqlite}" in
      sqlite) backend="sqlite" ;;
      pg)     backend="postgresql" ;;
      *) echo "[snails] unknown DB adapter: ${DB:-}" >&2; exit 1 ;;
    esac
    mkdir -p "$APP_ROOT/config"
    content="$(<"$SNAILS_ROOT/scaffold/new/config/database.rb")"
    printf '%s\n' "${content//__DB_BACKEND__/$backend}" > "$dst"
    echo "[snails] config/database.rb seeded: require_relative \"../$SNAILS_VENDOR_DIR/database/$backend\" — app-owned; edit it to switch adapters" >&2
  fi

  # Harness target (the test program that shares the core boot chain) — a core
  # default, created once from the scaffold when missing. Contents are
  # app-owned afterwards (sync never rewrites the directory). Gives every
  # app a runnable /up smoke; the app grows its own cases under test/.
  #
  # The runners are NOT seeded: they are CLI engines in the core engine
  # tree (`snails harness test|dev`), and the generated bin/test and bin/dev
  # wrappers hand off there. A copy in the app tree would drift from the
  # engine, so this directory seeds the harness boot and the case skeleton
  # only.
  if [[ ! -d "$APP_ROOT/harness" ]]; then
    cp -R "$SNAILS_ROOT/scaffold/harness" "$APP_ROOT/harness"
    created_from_scaffold "$APP_ROOT/harness"
  fi
  # The contract check's success line is its own result (verify-scaffold is
  # also a standalone command). Inside a sync it is one step, and the CLI's
  # result line reports the run; failures still abort through stderr.
  bash "$ENGINE_DIR/verify-scaffold.sh" "$APP_ROOT" >/dev/null
else
  if ((verbose)); then
    echo "[snails] scaffold contract skipped (no app files): $APP_ROOT" >&2
  else
    echo "[snails] scaffold contract skipped (no app files)" >&2
  fi
fi

if ((core_changed)); then
  if ((verbose)); then
    echo "[snails] done: $core_files files in $DST" >&2
  else
    echo "[snails] done: $core_files files" >&2
  fi
fi
