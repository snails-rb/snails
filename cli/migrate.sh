#!/bin/bash
# Schema migrations — the incremental half of the schema contract. The
# convention file (db/schema.sql — tables, indexes, views) provisions a
# FRESH database; this runner brings an EXISTING one forward, one ordered
# db/migrate/<version>_<name>[.<adapter>].sql at a time, recording what ran in
# schema_migrations. `dump` regenerates the schema dump from those same
# migration files — one writer, so the schema dump cannot drift from its
# history — and `verify` proves the committed schema dump equals that output,
# byte for byte.
#
# Contract:
#   - the file name's leading digits are the migration version, and files
#     run in ascending NUMERIC version order — the filesystem's collation
#     is not that order (one tree can mix a 4-digit ordinal version with
#     a 14-digit UTC timestamp version).
#   - forward-only: no down files. Rollback is restoring a backup.
#   - files are idempotent (tables/indexes IF NOT EXISTS, views DROP VIEW
#     IF EXISTS + CREATE VIEW), so an existing database adopts the ledger
#     by replaying: objects it already has are left alone.
#   - the schema dump is generated output: edit the migration files, then
#     `dump`. Never hand-edit db/schema.sql: the reasoning behind the schema
#     change belongs in the migration file, and `verify` fails on a hand edit.
#   - the runner owns transactions; a migration file must not carry its
#     own BEGIN/COMMIT.
#   - the executor is the adapter's CLI (sqlite3 / psql) and the runner is
#     bash (3.2-compatible, like the rest of the CLI): migrating a
#     database needs no interpreter beyond the adapter's own client.
#   - the app root is the directory that carries the database configuration;
#     with no --app it resolves to the nearest one at or above $PWD (walk up,
#     nearest wins). The pins file lives at that app root, so walking up is
#     all the resolution needs. The walk only works from inside the app; a
#     start outside it (a repository root above, say) resolves nothing, so
#     pass --app to name the app from there. A repository with several apps
#     gives each app its own pins file and its own app root.
#   - the runner refuses `apply` for a database owned by another app (pins
#     DB_OWNER="external"); status/verify stay available.
#   - `apply` writes only what the ledger says is pending, and the ledger
#     is created by the tool, never by the app's schema files.
#   - `check` is the read-only boot check: it exits 1 when any migration is
#     pending and prints the repair line by default (`--verbose` adds the
#     labels). It never writes; a ledger that cannot be read (no executor,
#     unreachable target) is a failure, never a silent pass.
#   - `dump` and `verify` derive the schema dump from the migration files
#     alone, never from a database's current state: sqlite reads no
#     target (`dump` takes no --database), while pg replays into a
#     throwaway schema on the target and drops it on exit.
#
# usage: snails migrate <status|apply|load|verify|check|dump> [--app DIR]
#                   [--database TARGET] [--verbose]
#
# exit: 0 = ok, 1 = violation (pending migration in check mode, ledger gap,
#        failed apply, schema dump drift), 2 = structural (usage, missing
#        pins or target, a schema dump guard — no migration files or tables,
#        an unsupported object, sqlite's --database, an external pg owner,
#        or no pg target)
set -euo pipefail

# The adapter detector is shared with the harness engines: one implementation
# of the "anchored require line is the adapter" rule.
MIGRATE_SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=database-adapter.sh
source "$MIGRATE_SCRIPTS/database-adapter.sh"
# App-root resolution is the CLI-wide rule: every surface that takes an app
# root sources the same file.
# shellcheck source=app-root.sh
source "$MIGRATE_SCRIPTS/app-root.sh"

LEDGER="schema_migrations"
DEFAULT_SQLITE="storage/development.sqlite3"
# Set by applied_versions: a database without the ledger has never been
# initialized, so the boot check asks for `migrate load` rather than apply.
LEDGER_PRESENT=0

usage() {
  cat <<'USAGE'
usage: snails migrate <status|apply|load|verify|check|dump> [--app DIR] [--database TARGET] [--verbose]

  status   applied/pending/not-applicable, plus a ledger gap check
  apply    run pending migrations in order, recording each in the ledger
  load     initialize the database: create it, load db/schema.sql, apply
           pending migrations, then refresh the schema dump
  verify   check the committed schema dump against the migration files
  dump     regenerate db/schema.sql (tables, indexes, views) from the
           migration files — the schema dump is generated output
  check    exit 1 when the database is uninitialized or a migration is
           pending (read-only; the boot check); --verbose lists the pending
           labels and the full repair command

Target resolution: --database, then the adapter env (DATABASE_PATH for
sqlite, PG_URL for pg), then <app>/storage/development.sqlite3.
dump reads no database on sqlite and takes no --database there; pg dump
and verify replay into a throwaway schema on the target
(--database or PG_URL) and drop it on exit.
App root: --app; else the nearest directory at or above $PWD carrying
config/database.rb (walk up, nearest wins). The pins file sits at that
app root, so a start outside the app needs --app.
The adapter comes from the app's config/database.rb; the ownership
comes from the project pins file (DB_OWNER=) discovered at or above
the app root.
USAGE
}

die() {
  local code="$1"
  shift
  echo "[snails] $*" >&2
  exit "$code"
}

# --- pins -------------------------------------------------------------------

# Read one key from a pins file. Accepted lines: comments (#), blank, and
# KEY="value" (the pins.toml contract) or a legacy bare KEY=value token;
# anything else is a violation, and the whole file is validated on every
# read — pins are declarations, never shell code (same rule as the CLI).
read_pins() {
  local file="$1" want="$2" line key val result=""
  while IFS= read -r line || [[ -n $line ]]; do
    [[ $line =~ ^[[:space:]]*$ || $line =~ ^[[:space:]]*# ]] && continue
    if [[ $line =~ ^([A-Za-z_][A-Za-z0-9_]*)=\"([^\"]*)\"$ ]]; then
      key="${BASH_REMATCH[1]}"
      val="${BASH_REMATCH[2]}"
    elif [[ $line =~ ^([A-Za-z_][A-Za-z0-9_]*)=([^[:space:]]+)$ ]]; then
      key="${BASH_REMATCH[1]}"
      val="${BASH_REMATCH[2]}"
    else
      die 2 "$file: not a pins declaration: $line"
    fi
    [[ $key == "$want" ]] && result="$val"
  done <"$file"
  printf '%s' "$result"
}

# Nearest pins file at or above <dir>, bounded by the directory holding
# .git — the same discovery the sync CLI uses. Prints nothing when absent.
discover_pins() {
  local cur="$1" parent
  while :; do
    if [[ -f "$cur/pins.toml" ]]; then
      printf '%s' "$cur/pins.toml"
      return 0
    fi
    [[ -e "$cur/.git" ]] && return 0
    parent="$(dirname "$cur")"
    [[ $parent == "$cur" ]] && return 0
    cur="$parent"
  done
}

# --- adapter executor ----------------------------------------------------------

# Both executors read the SQL on stdin. sqlite gets a busy wait in front of
# the transaction, so a concurrent writer waits instead of failing the
# apply; the shell's `.timeout` sets it without the echo a PRAGMA statement
# produces (stdout is the result summary only). psql stops at the first error
# and stays quiet.
sql_exec() {
  if [[ $DB_ADAPTER == sqlite ]]; then
    printf '.timeout 30000\n%s\n' "$1" | sqlite3 -bail "$TARGET"
  else
    printf '%s\n' "$1" | psql "$TARGET" -v ON_ERROR_STOP=1 -X -q -f -
  fi
}

# The ledger and the catalog are read through the adapter's CLI. A missing
# executor means the check cannot run — it must fail, never read as "nothing
# pending".
require_executor() {
  local tool=sqlite3
  [[ $DB_ADAPTER == sqlite ]] || tool=psql
  command -v "$tool" >/dev/null 2>&1 && return 0
  die 2 "the $DB_ADAPTER executor '$tool' is not on PATH — install it; the ledger cannot be read without it"
}

# Scalar query rows (one value per line) — the ledger, and the catalog
# probes. Each adapter has its own catalog: sqlite_master vs
# information_schema.
sql_rows() {
  if [[ $DB_ADAPTER == sqlite ]]; then
    sqlite3 "$TARGET" "$1"
  else
    psql "$TARGET" -v ON_ERROR_STOP=1 -X -tA -c "$1"
  fi
}

ledger_exists() {
  local probe
  if [[ $DB_ADAPTER == sqlite ]]; then
    probe="SELECT name FROM sqlite_master WHERE type = 'table' AND name = '$LEDGER'"
  else
    probe="SELECT table_name FROM information_schema.tables WHERE table_schema = 'public' AND table_name = '$LEDGER'"
  fi
  [[ -n "$(sql_rows "$probe")" ]]
}

# Reading must not create the target: the sqlite3 CLI creates a missing
# file on open, so status on a fresh checkout would leave an empty
# database behind. A missing sqlite target simply has nothing applied.
target_exists() {
  [[ $DB_ADAPTER == sqlite ]] || return 0
  [[ -f $TARGET ]]
}

applied_versions() {
  target_exists || return 0
  require_executor
  ledger_exists || return 0
  sql_rows "SELECT version FROM $LEDGER ORDER BY version"
}

# has <needle> <newline-separated haystack>
has() {
  [[ $'\n'"$2"$'\n' == *$'\n'"$1"$'\n'* ]]
}

in_versions() {
  local version
  for version in ${VERSIONS[@]+"${VERSIONS[@]}"}; do
    [[ $version == "$1" ]] && return 0
  done
  return 1
}

index_of_version() {
  local i=0
  while ((i < ${#VERSIONS[@]})); do
    if [[ ${VERSIONS[$i]} == "$1" ]]; then
      printf '%s' "$i"
      return 0
    fi
    i=$((i + 1))
  done
  return 1
}

# --- migrations listing -----------------------------------------------------

# List db/migrate/*.sql into parallel arrays: VERSIONS, LABELS, PATHS for
# the migrations this adapter applies, NOT_APPLICABLE for versions that only
# carry another adapter's file. A version resolves to its adapter file when one
# exists, else to the common file; two names under one version are a
# violation, and a name may not move across versions.
#
# Order is the version's NUMERIC value (the leading digits of the file
# name), not the shell's glob collation: one tree can carry a short
# ordinal version and a 14-digit timestamp version, and as text "2100"
# sorts after "20261026120000", but as a number it comes first. Sorting
# also keeps every file of one version adjacent, which the pairing below
# relies on.
list_migrations() {
  VERSIONS=()
  LABELS=()
  PATHS=()
  NOT_APPLICABLE=()
  [[ -d $MIGRATE_DIR ]] || return 0

  CUR_VERSION=""
  CUR_NAME=""
  CUR_COMMON=""
  CUR_ADAPTER=""
  # Names already closed by an earlier version — a name may not move
  # across versions (files that share a version and a name are the adapter
  # variants of one migration, which is normal).
  PREV_NAMES=""

  local file base names=""
  for file in "$MIGRATE_DIR"/*.sql; do
    [[ -f $file ]] || continue
    names="$names${file##*/}"$'\n'
  done
  [[ -n $names ]] || return 0

  local sorted
  sorted="$(printf '%s' "$names" | LC_ALL=C sort -n)"
  while IFS= read -r file; do
    [[ -n $file ]] || continue
    base="${file%.sql}"
    if [[ $base =~ ^([0-9]{4,})_([A-Za-z0-9_-]+)(\.(sqlite|pg))?$ ]]; then
      add_migration "$MIGRATE_DIR/$file" "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[4]}"
    else
      die 1 "$base.sql: expected <version>_<name>[.<adapter>].sql (UTC timestamp version: date -u +%Y%m%d%H%M%S)"
    fi
  done <<<"$sorted"
  flush_version
}

add_migration() { # <file> <version> <name> <adapter-or-empty>
  local file="$1" version="$2" name="$3" adapter="$4"
  if [[ $version != "$CUR_VERSION" ]]; then
    flush_version
    CUR_VERSION="$version"
    CUR_NAME=""
    CUR_COMMON=""
    CUR_ADAPTER=""
  fi
  if [[ -n $CUR_NAME && $name != "$CUR_NAME" ]]; then
    die 1 "two migrations share version $version: $CUR_NAME and $name — rename one file to a new timestamp, or delete the duplicate"
  fi
  if [[ " $PREV_NAMES " == *" $name "* ]]; then
    die 1 "the migration name $name appears under more than one version — rename one of the files"
  fi
  CUR_NAME="$name"

  [[ -z $adapter ]] && CUR_COMMON="$file"
  [[ $adapter == "$DB_ADAPTER" ]] && CUR_ADAPTER="$file"
  # A failing `[[ ]] &&` test leaves a non-zero status; without this return,
  # the function would return non-zero and `set -e` would end the run (a file
  # for another adapter is normal, not an error).
  return 0
}

# Close the version being collected: the adapter file wins, else the common
# file, else the version does not apply to this adapter.
flush_version() {
  [[ -n $CUR_VERSION ]] || return 0
  local label="$CUR_VERSION"_"$CUR_NAME" chosen="$CUR_ADAPTER"
  PREV_NAMES="$PREV_NAMES $CUR_NAME"
  [[ -n $chosen ]] || chosen="$CUR_COMMON"
  if [[ -n $chosen ]]; then
    VERSIONS[${#VERSIONS[@]}]="$CUR_VERSION"
    LABELS[${#LABELS[@]}]="$label"
    PATHS[${#PATHS[@]}]="$chosen"
  else
    NOT_APPLICABLE[${#NOT_APPLICABLE[@]}]="$label"
  fi
}

# --- commands ---------------------------------------------------------------

orphan_versions() {
  local version orphans=""
  for version in ${APPLIED:-}; do
    in_versions "$version" || orphans="${orphans:+$orphans, }$version"
  done
  printf '%s' "$orphans"
}

orphan_versions_sql() {
  local version sql=""
  for version in ${APPLIED:-}; do
    in_versions "$version" || sql="${sql:+$sql, }'$version'"
  done
  printf '%s' "$sql"
}

# Every command refuses the same broken state: the ledger names versions that
# db/migrate no longer has. The repair reconciles the two either way, so one
# message shape carries it.
die_orphans() {
  local versions sql kind="version" pronoun="it" rows="row" files="file"
  versions="$(orphan_versions)"
  [[ -n $versions ]] || return 0
  sql="$(orphan_versions_sql)"
  if [[ $versions == *,* ]]; then
    kind="versions" pronoun="them" rows="rows" files="files"
  fi
  die 1 "the ledger records $kind $versions with no migration $files — restore $pronoun, or delete the ledger $rows: DELETE FROM schema_migrations WHERE version IN ($sql)"
}

cmd_status() {
  local i=0 state width=0 label
  # One width for both the applied/pending rows and the n/a rows: a long
  # timestamp label otherwise pushes the state column out of the grid.
  for label in ${LABELS[@]+"${LABELS[@]}"} ${NOT_APPLICABLE[@]+"${NOT_APPLICABLE[@]}"}; do
    (( ${#label} > width )) && width=${#label}
  done

  # Print the counts first; the per-file rows are the detail. Pending
  # migrations are not a failure here; `check` is the gate.
  printf '[snails] %s applied, %s pending\n' "${#APPLIED_LIST[@]}" "${#PENDING[@]}"

  while ((i < ${#VERSIONS[@]})); do
    if has "${VERSIONS[$i]}" "${APPLIED:-}"; then
      state="applied"
    else
      state="pending"
    fi
    printf "%-${width}s %s\n" "${LABELS[$i]}" "$state"
    i=$((i + 1))
  done
  for label in ${NOT_APPLICABLE[@]+"${NOT_APPLICABLE[@]}"}; do
    printf "%-${width}s n/a (no %s file)\n" "$label" "$DB_ADAPTER"
  done

  die_orphans
}

# The command the developer can paste back into the same shell. An empty
# app argument omits --app (the current directory is the app root).
repair_command() { # <app-arg> <database-arg> <apply|load>
  local app_arg="$1" database_arg="$2" subcommand="${3:-apply}" command
  if [[ -n ${SNAILS_MIGRATE_REPAIR:-} ]]; then
    # The deployment that runs this copy supplies the host-side command: the
    # shell that can reach the deployed database is not the one inside the
    # container. The app argument is also dropped; the host form resolves the
    # compose project from the caller's directory.
    command="$SNAILS_MIGRATE_REPAIR"
    app_arg=""
  else
    command="snails migrate $subcommand"
  fi
  [[ -n $app_arg ]] && command+=" --app $(shell_quote "$app_arg")"
  [[ -n $database_arg ]] && command+=" --database $(shell_quote "$database_arg")"
  printf '%s' "$command"
}

# The boot check. Success is silent: the dev runner calls it on every boot
# and has its own progress lines. A failure prints only the repair line;
# --verbose adds the pending labels. Read-only: the repair is the explicit
# `migrate load` (uninitialized) or `migrate apply` (pending) step, never this
# command.
cmd_check() {
  local n="${#PENDING[@]}" version i message app_arg="" command full_command
  local subcommand=apply
  die_orphans
  ((LEDGER_PRESENT)) || subcommand=load

  if ((n == 0)); then
    # A schema-only app has no migration file to count. The missing ledger is
    # the signal that the schema dump was never loaded, so the boot still asks
    # for the explicit initialization instead of starting against an empty DB.
    if ((LEDGER_PRESENT == 0)) && [[ -f $APP/db/schema.sql ]]; then
      if [[ $OWNER == external ]]; then
        message="database is not initialized — DB_OWNER=\"external\": another app owns this database, so provision it there"
      else
        app_arg="$(app_root_argument "$APP")"
        command="$(repair_command "$app_arg" "$DB_OPTION" load)"
        message="database is not initialized — run: $command"
      fi
      echo "[snails] $message" >&2
      exit 1
    fi
    return 0
  fi

  # The repair line comes first even with --verbose: the labels are detail
  # that follows it, never what the reader sees first.
  if [[ $OWNER == external ]]; then
    message="$n pending migration(s) — DB_OWNER=\"external\": another app owns this database, so migrate it there"
  else
    # An empty app argument means the current directory is the app root:
    # the shared resolver finds it again, so the shortest command omits --app.
    app_arg="$(app_root_argument "$APP")"
    command="$(repair_command "$app_arg" "$DB_OPTION" "$subcommand")"
    message="$n pending migration(s) — run: $command"
  fi
  echo "[snails] $message" >&2
  if ((VERBOSE)); then
    # Keep the full argument form for logs, where the reader's shell may no
    # longer be available.
    if [[ $OWNER != external ]]; then
      full_command="$(repair_command "$APP" "$DB_OPTION" "$subcommand")"
      [[ $full_command == "$command" ]] || echo "  full: $full_command" >&2
    fi
    for version in "${PENDING[@]}"; do
      i="$(index_of_version "$version")"
      echo "  pending ${LABELS[$i]}" >&2
    done
  fi
  exit 1
}

ensure_ledger() {
  ledger_exists && return 0
  sql_exec "CREATE TABLE $LEDGER (version TEXT PRIMARY KEY NOT NULL, applied_at TEXT NOT NULL);" ||
    die 1 "could not create $LEDGER"
}

# The runner owns the transaction; a file carrying its own control flow is
# refused rather than nested.
transaction() {
  local path="$1" version="$2" stamp
  if grep -Eiq '^[[:space:]]*(BEGIN|COMMIT|ROLLBACK)([[:space:]]|;|$)' "$path"; then
    die 1 "$(basename "$path"): migration files must not carry their own BEGIN/COMMIT (the runner owns the transaction)"
  fi
  stamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  sql_exec "BEGIN;
$(cat "$path")
INSERT INTO $LEDGER (version, applied_at) VALUES ('$version', '$stamp');
COMMIT;"
}

# The default sqlite target lives under the app's storage/ (gitignored), so
# a fresh clone has no directory for it. Write commands create it; the
# read-only commands still never write one.
ensure_target_dir() {
  [[ $DB_ADAPTER == sqlite ]] || return 0
  local target_dir
  target_dir="$(dirname "$TARGET")"
  mkdir -p "$target_dir" || die 1 "could not create the sqlite target directory: $target_dir"
}

cmd_apply() {
  die_orphans

  if ((${#PENDING[@]} == 0)); then
    echo "nothing to apply"
    return 0
  fi
  ensure_target_dir
  ensure_ledger
  local version i
  for version in "${PENDING[@]}"; do
    i="$(index_of_version "$version")"
    echo "applying ${LABELS[$i]}" >&2
    transaction "${PATHS[$i]}" "$version" || die 1 "apply failed: ${LABELS[$i]}"
  done
  printf '%s applied\n' "${#PENDING[@]}"
}

# Load the committed schema dump into the target. A migration-owning app uses
# this only before the ledger exists — replaying ALTER-style migrations over
# an initialized database is not safe. A schema-only app reloads the schema
# dump on every load because it has no migration path.
load_schema_dump() {
  local schema_file="$APP/db/schema.sql"
  [[ -f $schema_file ]] || return 0
  echo "[snails] loading db/schema.sql" >&2
  if [[ $DB_ADAPTER == sqlite ]]; then
    {
      printf '.timeout 30000\nBEGIN;\n'
      cat "$schema_file"
      printf '\nCOMMIT;\n'
    } | sqlite3 -bail "$TARGET" || die 1 "schema load failed: db/schema.sql"
  else
    psql "$TARGET" -v ON_ERROR_STOP=1 -X -q --single-transaction -f "$schema_file" ||
      die 1 "schema load failed: db/schema.sql"
  fi
}

# `migrate dump` is the only writer of the schema dump; load delegates to it
# so the schema file it just loaded and the migration history stay in step.
run_dump() {
  local args=(dump --app "$APP")
  if [[ $DB_ADAPTER == pg ]]; then
    args+=(--database "$TARGET")
  fi
  ((VERBOSE)) && args+=(--verbose)
  bash "$MIGRATE_SCRIPTS/migrate.sh" "${args[@]}"
}

# The explicit setup command: the equivalent of Rails' db:prepare. A fresh
# database is created, the schema dump is loaded when one exists, pending
# migrations are replayed to record the ledger, and the schema dump is
# regenerated from the files. An initialized migration-owning database skips
# the schema dump load and only applies pending migrations; a schema-only app
# reloads its schema dump because it has no migration path.
cmd_load() {
  die_orphans

  if ((${#VERSIONS[@]} == 0)) && [[ ! -f $APP/db/schema.sql ]]; then
    echo "nothing to load"
    return 0
  fi

  ensure_target_dir
  # A schema-only app has no migration path, so its schema dump is the schema:
  # reload it every time. A migration-owning app loads it only when the
  # target has no ledger — replaying ALTER-style migrations over an
  # initialized database is not safe.
  if ((LEDGER_PRESENT == 0)) || ((${#VERSIONS[@]} == 0)); then
    load_schema_dump
  fi
  if ((${#PENDING[@]} > 0)); then
    cmd_apply
  else
    # A schema-only app has no migration to create the ledger; the empty
    # table still marks the database as initialized for the boot check.
    ensure_ledger
  fi
  if ((${#VERSIONS[@]} > 0)); then
    run_dump
  fi
  echo "[snails] database ready"
}

# --- schema dump generation ------------------------------------------------

# Replay every migration file into <db> in version order — the same run
# `apply` performs, minus the ledger: the schema dump is the files' result,
# not an adoption record.
replay_into() { # <db>
  local db="$1" i=0
  while ((i < ${#VERSIONS[@]})); do
    sqlite3 -bail "$db" <"${PATHS[$i]}" || die 1 "replay failed: ${LABELS[$i]}"
    i=$((i + 1))
  done
}

# The header every generated schema dump carries: it names the file's writer,
# so a hand edit has an authoritative source to compare against.
schema_dump_header() {
  printf '%s\n' \
    '-- Generated by snails migrate dump from db/migrate/*.sql — do not edit.' \
    '-- Edit the migration files, then re-run snails migrate dump.'
}

# sqlite stores a CREATE statement without the IF NOT EXISTS clause that the
# file was written with; the schema dump adds it back, so re-loading a schema
# dump over an existing database stays a no-op (the contract's idempotency).
# The
# match runs case-insensitively over the statement's first line, and the
# insert measures the ORIGINAL text — the writer keeps the statement's own
# case and spacing (the uppercased copy is used only for comparison).
ensure_if_not_exists() { # <statement> → stdout
  local stmt="$1" first rest prelen had_nocase=0
  if shopt -q nocasematch; then had_nocase=1; fi
  shopt -s nocasematch
  stmt="${stmt#"${stmt%%[![:space:]]*}"}"
  if [[ $stmt == *$'\n'* ]]; then
    first="${stmt%%$'\n'*}"
    rest=$'\n'"${stmt#*$'\n'}"
  else
    first="$stmt"
    rest=""
  fi
  if [[ $first =~ ^([[:space:]]*CREATE[[:space:]]+(UNIQUE[[:space:]]+|VIRTUAL[[:space:]]+)?(TABLE|INDEX)[[:space:]]+)(IF[[:space:]]+NOT[[:space:]]+EXISTS[[:space:]]+)?([^[:space:]].*)$ ]] &&
    [[ -z ${BASH_REMATCH[4]:-} ]]; then
    prelen=${#BASH_REMATCH[1]}
    printf '%sIF NOT EXISTS %s%s' "${first:0:prelen}" "${first:prelen}" "$rest"
  else
    printf '%s%s' "$first" "$rest"
  fi
  if ((had_nocase == 0)); then shopt -u nocasematch; fi
  return 0
}

# The EXIT trap for dump/verify: the temp tree, plus pg's throwaway
# schema if one was created (success, die, or crash path).
cleanup_schema_dump() { # <tmp>
  rm -rf "$1"
  if [[ -n ${PG_SCRATCH:-} && -n ${TARGET:-} ]]; then
    psql "$TARGET" -q -c "DROP SCHEMA IF EXISTS $PG_SCRATCH CASCADE" >/dev/null 2>&1 || true
  fi
  return 0
}

# pg: replay into a throwaway schema on the target. The target is only
# scratch space; the schema dump still comes from the migration files, never
# from the target's state.
replay_into_pg() {
  PG_SCRATCH="snails_dump_$$_$RANDOM"
  psql "$TARGET" -q -c "DROP SCHEMA IF EXISTS $PG_SCRATCH CASCADE" >/dev/null 2>&1 || true
  psql "$TARGET" -v ON_ERROR_STOP=1 -q -c "CREATE SCHEMA $PG_SCRATCH" ||
    die 1 "could not create the throwaway schema $PG_SCRATCH"
  local i=0
  while ((i < ${#VERSIONS[@]})); do
    { printf 'SET search_path TO %s;\nSET client_min_messages TO warning;\n' "$PG_SCRATCH"; cat "${PATHS[$i]}"; } |
      psql "$TARGET" -v ON_ERROR_STOP=1 -X -q -f - ||
      die 1 "replay failed: ${LABELS[$i]}"
    i=$((i + 1))
  done
  SCHEMA_DUMP_STATEMENTS="$(psql "$TARGET" -tA -c \
    "SELECT count(*) FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = '$PG_SCRATCH' AND c.relkind IN ('r','v','i','S')")"
}

# Render the throwaway schema through pg_dump — the standard renderer, so
# serials, sequences, constraints, and comments come out right. Strip what
# must not reach a fresh database: session settings, pg_dump's own banner
# comments, psql meta-commands (pg17+ \restrict), and the throwaway schema
# qualifier (the schema dump must load into whatever search_path the loader
# runs with). setval lines are dropped too: a rowless schema dump's sequences
# start at their default.
pg_schema_dump() { # <out_file>
  command -v pg_dump >/dev/null 2>&1 ||
    die 2 "the pg executor 'pg_dump' is not on PATH — install it"
  {
    schema_dump_header
    printf '\n'
    # pg_dump's own output, kept as a structure dump, including the
    # SET block: a schema dump records the client that rendered it, and a
    # server that does not recognize those settings SHOULD fail to load it.
    # The version pairing is a requirement the environment must satisfy:
    # dump needs pg_dump >= the server, and a load needs a server >= the
    # pg_dump that wrote the file, so the working pair is the same major
    # version. Only constructs that the throwaway-schema pipeline invalidates
    # are removed:
    #   psql meta (\restrict/\unrestrict) — stripped here too; a
    #     psql older than the pg_dump that wrote the file errors on them.
    #   set_config('search_path','',false) — clears the search path for which
    #     the qualifier strip below has no replacement; the two must be
    #     removed together.
    #   CREATE SCHEMA, the schema qualifier, and every `-- ` line — they name
    #     the throwaway schema (pid + random per run), which would leak into
    #     every regenerated schema dump and make it unstable; the version
    #     banner goes out with the comments.
    pg_dump --schema-only --no-owner --no-privileges --schema="$PG_SCRATCH" "$TARGET" |
      sed -e '/^\\restrict /d' \
          -e '/^\\unrestrict /d' \
          -e '/^SELECT pg_catalog\.set_config(/d' \
          -e '/^CREATE SCHEMA '"$PG_SCRATCH"'\;/d' \
          -e "s/$PG_SCRATCH\.//g" \
          -e '/^--/d'
  } >"$1"
}

# build_schema_dump <out_dir> — write <out_dir>/schema.sql from the migration
# files and set SCHEMA_DUMP_STATEMENTS. sqlite replays into a temp file; pg
# replays into a throwaway schema on the target (dropped by the trap).
build_schema_dump() {
  local out="$1"
  mkdir -p "$out"
  if [[ $DB_ADAPTER == pg ]]; then
    [[ $OWNER == external ]] &&
      die 2 "DB_OWNER=\"external\": $PINS declares this database is owned by another app — dump would write a throwaway schema there"
    replay_into_pg
    ((SCHEMA_DUMP_STATEMENTS > 0)) ||
      die 2 "the migrations create no objects — refusing to write an empty schema dump"
    pg_schema_dump "$out/schema.sql"
    return 0
  fi
  local replay="$out/.replay.db"
  replay_into "$replay"
  local tables
  tables="$(sqlite3 "$replay" "SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'")"
  ((tables > 0)) ||
    die 2 "the migrations create no tables — refusing to write an empty schema dump"
  generate_schema_dump "$replay" "$out"
  rm -f "$replay"
}
# generate_schema_dump <replay_db> <out_dir> — write <out_dir>/schema.sql from
# the replayed catalog; sets SCHEMA_DUMP_STATEMENTS to the statement count.
#
# One file, the form every dump tool emits (structure.sql, pg_dump,
# sqlite3 .dump): tables and indexes first, then views, each group in the
# catalog's rowid order. Putting views last makes a single pass safe on both
# adapters: every table an inline view reads already precedes it, and within
# the group a pg history can only end in creation order (pg rejects a view
# over a missing relation and a drop under a dependent view, so a recreated
# dependency always lands before its dependent). sqlite never validates view
# bodies at all. Tables and indexes keep IF NOT EXISTS (sqlite strips it from
# stored DDL); views keep the plain CREATE VIEW the hand-written files
# carried — the schema dump only needs to provision a fresh database.
generate_schema_dump() { # <replay_db> <out_dir>
  local db="$1" out="$2" rid type name sql table_body="" view_body="" body ids
  SCHEMA_DUMP_STATEMENTS=0
  ids="$(sqlite3 "$db" "SELECT rowid FROM sqlite_master WHERE sql IS NOT NULL AND name NOT LIKE 'sqlite_%' AND name != '$LEDGER' ORDER BY rowid")"
  mkdir -p "$out"
  for rid in $ids; do
    type="$(sqlite3 "$db" "SELECT type FROM sqlite_master WHERE rowid = $rid")"
    name="$(sqlite3 "$db" "SELECT name FROM sqlite_master WHERE rowid = $rid")"
    sql="$(sqlite3 "$db" "SELECT sql FROM sqlite_master WHERE rowid = $rid")"
    SCHEMA_DUMP_STATEMENTS=$((SCHEMA_DUMP_STATEMENTS + 1))
    if [[ $type != table && $type != index && $type != view ]]; then
      die 2 "unsupported object in the migrations: $type $name — the schema dump covers tables, indexes, and views"
    fi
    sql="$(ensure_if_not_exists "$sql")"
    if [[ $type == view ]]; then
      if [[ -n $view_body ]]; then view_body+=$'\n'; fi
      view_body+="$sql;"
    else
      if [[ -n $table_body ]]; then table_body+=$'\n'; fi
      table_body+="$sql;"
    fi
  done
  body="$table_body"
  if [[ -n $view_body ]]; then
    if [[ -n $body ]]; then body+=$'\n'; fi
    body+="$view_body"
  fi
  {
    schema_dump_header
    if [[ -n $body ]]; then
      printf '\n%s\n' "$body"
    else
      printf '\n'
    fi
  } >"$out/schema.sql"
}

# The schema dump writer: regenerate the schema file from the migration
# files. One writer prevents drift; `verify` compares against exactly this
# output.
cmd_dump() {
  require_executor
  ((${#VERSIONS[@]})) ||
    die 2 "no migration files in db/migrate — refusing to write an empty schema dump"

  local tmp
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064  # $tmp is resolved here, on purpose
  trap "cleanup_schema_dump '$tmp'" EXIT
  build_schema_dump "$tmp/snap"
  local statements="$SCHEMA_DUMP_STATEMENTS"

  # Content-gated write through a same-directory temp file: an unchanged
  # file keeps its mtime (the harness bundle cache uses them), and an
  # interrupted dump never leaves a half-written schema dump behind.
  local changed=0 detail=""
  mkdir -p "$APP/db"
  if [[ ! -f $APP/db/schema.sql ]] || ! cmp -s "$tmp/snap/schema.sql" "$APP/db/schema.sql"; then
    cp "$tmp/snap/schema.sql" "$APP/db/.schema.sql.dump.$$"
    mv "$APP/db/.schema.sql.dump.$$" "$APP/db/schema.sql"
    changed=1
    if ((VERBOSE)); then detail+="  db/schema.sql"$'\n'; fi
  fi

  if ((changed)); then
    printf '[snails] schema dump regenerated (%s statements)\n' "$statements"
  else
    printf '[snails] schema dump is up to date (%s statements)\n' "$statements"
  fi
  if ((VERBOSE)) && [[ -n $detail ]]; then
    printf '%s' "$detail" >&2
  fi
}

# The gate: the committed schema dump must equal what `dump` regenerates from
# the same migration files, byte for byte, so a hand edit and a forgotten
# regeneration are one failure with one repair (`dump`).
cmd_verify() {
  require_executor

  die_orphans

  local tmp
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064  # $tmp is resolved here, on purpose
  trap "cleanup_schema_dump '$tmp'" EXIT
  build_schema_dump "$tmp/snap"

  local problems=() rel
  if [[ ! -f $APP/db/schema.sql ]]; then
    problems+=("db/schema.sql: missing")
  elif ! cmp -s "$tmp/snap/schema.sql" "$APP/db/schema.sql"; then
    problems+=("db/schema.sql: differs")
  fi

  if ((${#problems[@]} == 0)); then
    printf 'schema dump matches the migrate replay (%s statements)\n' "$SCHEMA_DUMP_STATEMENTS"
    return 0
  fi

  # The repair comes first; the per-file reasons follow. The unified diff of
  # every differing file is the --verbose detail.
  local app_arg repair p
  app_arg="$(app_root_argument "$APP")"
  repair="snails migrate dump"
  if [[ -n $app_arg ]]; then repair+=" --app $(shell_quote "$app_arg")"; fi
  echo "[snails] schema dump differs from the migrate replay — run: $repair" >&2
  for p in "${problems[@]}"; do
    printf '  %s\n' "$p" >&2
  done
  if ((VERBOSE)); then
    for p in "${problems[@]}"; do
      rel="${p%%:*}"
      case "$p" in
        *missing) diff -u /dev/null "$tmp/snap/${rel#db/}" >&2 || true ;;
        *) diff -u "$APP/$rel" "$tmp/snap/${rel#db/}" >&2 || true ;;
      esac
    done
  fi
  exit 1
}

# --- main -------------------------------------------------------------------

COMMAND=""
if (($#)); then
  COMMAND="$1"
  shift
fi
case "$COMMAND" in
  "" | help | -h | --help)
    usage
    exit 0
    ;;
  status | apply | load | verify | check | dump) ;;
  *)
    die 2 "unknown command: $COMMAND — run 'snails help migrate'"
    ;;
esac

APP=""
DB_OPTION=""
VERBOSE=0
while (($#)); do
  case "$1" in
    --app)
      APP="${2:-}"
      [[ -n $APP ]] || die 2 "--app needs a value — run 'snails help migrate'"
      shift 2
      ;;
    --database)
      DB_OPTION="${2:-}"
      [[ -n $DB_OPTION ]] || die 2 "--database needs a value — run 'snails help migrate'"
      shift 2
      ;;
    --verbose) VERBOSE=1; shift ;;
    *) die 2 "unknown option: $1 — run 'snails help migrate'" ;;
  esac
done
if [[ -n $APP ]]; then
  # Normalize first: pins discovery climbs from the app root, and a relative
  # --app would stop it at "." instead of the app directory. An explicit
  # --app may name the repository root of a src/ layout; this is the same
  # rule the build engines use.
  APP_INPUT="$APP"
  [[ -d $APP_INPUT ]] || die 2 "no such app root: $APP_INPUT — pass the directory that holds config/database.rb"
  APP="$(cd "$APP_INPUT" && pwd)" || die 2 "no such app root: $APP_INPUT — pass the directory that holds config/database.rb"
  APP="$(app_root_for "$APP")"
else
  APP="$(resolve_app_root '[snails]' '--app DIR')" || exit 2
fi

PINS="$(discover_pins "$APP")"
[[ -n $PINS ]] || die 2 "no pins file at or above $APP — add pins.toml (snails new stamps one)"
[[ -f $PINS ]] || die 2 "pins file not found: $PINS — add pins.toml (snails new stamps one)"

DB_ADAPTER="$(database_adapter_for "$APP")" || exit 2

# sqlite dump reads migration files only; a target would make the command's
# result misleading. pg dump and verify need the target as their scratch.
if [[ $COMMAND == dump && $DB_ADAPTER == sqlite && -n $DB_OPTION ]]; then
  die 2 "dump does not take --database (the schema dump comes from the migration files)"
fi

OWNER="$(read_pins "$PINS" DB_OWNER)"
OWNER="${OWNER:-self}"
case " $OWNER " in
  " self " | " external ") ;;
  *) die 2 "unknown DB_OWNER: $OWNER — must be \"self\" or \"external\"" ;;
esac

# Every command that reads or writes the database resolves the target before
# dispatch. The external-owner refusal for apply/load is a declaration check,
# so a target owned by another app is refused whether or not a server answers.
resolve_target() {
  local adapter_env="" env_value=""
  case "$DB_ADAPTER" in
    sqlite)
      adapter_env="DATABASE_PATH"
      env_value="${DATABASE_PATH:-}"
      ;;
    pg)
      adapter_env="PG_URL"
      env_value="${PG_URL:-}"
      ;;
  esac
  TARGET="${DB_OPTION:-$env_value}"
  if [[ -z $TARGET && $DB_ADAPTER == sqlite ]]; then
    TARGET="$APP/$DEFAULT_SQLITE"
  fi
  if [[ -z $TARGET ]]; then
    die 2 "no $DB_ADAPTER target: pass --database or set $adapter_env"
  fi
  return 0
}

TARGET=""
case "$COMMAND" in
  status | apply | load | verify | check) resolve_target ;;
  dump)
    if [[ $DB_ADAPTER == pg ]]; then resolve_target; fi
    ;;
esac
if [[ ($COMMAND == apply || $COMMAND == load) && $OWNER == external ]]; then
  die 2 "DB_OWNER=\"external\": $PINS declares this database is owned by another app — migrate it there"
fi

MIGRATE_DIR="$APP/db/migrate"
list_migrations

APPLIED=""
if [[ -n $TARGET ]]; then
  APPLIED="$(applied_versions)"
  # applied_versions runs in a command substitution (a subshell), so the
  # parent decides the flag: an existing ledger means the target has been
  # initialized. A missing sqlite target is checked before ledger_exists so
  # the read never creates the file.
  if target_exists && ledger_exists; then
    LEDGER_PRESENT=1
  fi
fi
APPLIED_LIST=()
PENDING=()
i=0
while ((i < ${#VERSIONS[@]})); do
  if has "${VERSIONS[$i]}" "${APPLIED:-}"; then
    APPLIED_LIST[${#APPLIED_LIST[@]}]="${VERSIONS[$i]}"
  else
    PENDING[${#PENDING[@]}]="${VERSIONS[$i]}"
  fi
  i=$((i + 1))
done

case "$COMMAND" in
  status) cmd_status ;;
  apply) cmd_apply ;;
  load) cmd_load ;;
  verify) cmd_verify ;;
  check) cmd_check ;;
  dump) cmd_dump ;;
esac
