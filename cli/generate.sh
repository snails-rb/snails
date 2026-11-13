#!/bin/bash
# `snails generate <generator> [<app_root>]` — stamp a feature's files
# into an app tree: the generator names
# the feature, the app tree keeps the files.
#
# One generator ships today:
#
#   job_queue — the DB-backed job queue. Writes the migration history
#           (db/migrate/<UTC version>_create_snails_queue[.pg].sql) and
#           regenerates the schema dump (db/schema.sql) with `migrate dump`
#           — one writer, so the generated history and the committed
#           schema dump agree by construction (pg needs PG_URL: dump
#           replays the migrations into a throwaway schema on it). Then
#           prints the config/environment.rb wiring lines (the queue
#           adapter selection, plus the retention registration commented
#           out — retention is opt-in). The DDL template lives in
#           scaffold/queue/ — the same file the core harness contract
#           cases read, so the bytes stamped into an app are the bytes
#           under contract.
#
# The schema dump and the migration are written together (a schema dump is
# provisioning, a migration is history), and both directions of
# idempotency are one-line results: an existing migration stops the
# run, and queue tables already in the schema dump mean the app owns its
# own history.
#
# Usage:
#   bash cli/generate.sh queue [<app_root>]
#   <app_root> omitted resolves through cli/app-root.sh (nearest
#   database configuration at or above $PWD; outside the app, pass it).
#
# Exit: 0 written · 0 already present · 2 usage (unknown generator or
# flag, unresolvable app root, missing or ambiguous database
# configuration)
set -euo pipefail

# App-root resolution and adapter detection are shared engines — one
# rule for every surface.
GEN_SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=app-root.sh
source "$GEN_SCRIPTS/app-root.sh"
# shellcheck source=database-adapter.sh
source "$GEN_SCRIPTS/database-adapter.sh"

QUEUE_TEMPLATE_SQLITE="create_snails_queue.sql"
QUEUE_TEMPLATE_PG="create_snails_queue.pg.sql"

die() {
  local code="$1"
  shift
  echo "[snails] $*" >&2
  exit "$code"
}

generator="${1:-}"
case "$generator" in
  "")  die 2 "usage: snails generate <generator> [<app_root>] — generators: job_queue" ;;
  job_queue) shift ;;
  *)   die 2 "unknown generator: $generator — generators: job_queue" ;;
esac

app_root="${1:-}"
if (($# > 1)); then
  die 2 "usage: snails generate job_queue [<app_root>]"
fi
if [[ -z $app_root ]]; then
  app_root="$(resolve_app_root '[snails]' '<app_root>')" || exit 2
else
  # An explicit argument may be the repository root of a src/ layout; the
  # omitted case resolves the same root through resolve_app_root.
  app_root="$(app_root_for "$app_root")"
fi
[[ -d $app_root ]] || die 2 "no such app_root: $app_root"

adapter="$(database_adapter_for "$app_root")" || exit 2

template="$GEN_SCRIPTS/../scaffold/queue/$QUEUE_TEMPLATE_SQLITE"
migration_name="$QUEUE_TEMPLATE_SQLITE"
if [[ $adapter == pg ]]; then
  template="$GEN_SCRIPTS/../scaffold/queue/$QUEUE_TEMPLATE_PG"
  migration_name="$QUEUE_TEMPLATE_PG"
fi
[[ -f $template ]] || die 1 "missing queue template: scaffold/queue/$migration_name"

# One already-generated migration ends the run — the app owns whatever
# history follows from it.
existing_migration=""
for candidate in "$app_root"/db/migrate/*_create_snails_queue*.sql; do
  [[ -f $candidate ]] || continue
  existing_migration="$candidate"
  break
done
if [[ -n $existing_migration ]]; then
  echo "[snails] job_queue migration already present: ${existing_migration#"$app_root"/} — nothing to do"
  exit 0
fi

# Queue tables in the schema dump mean the app already carries the queue
# (its own migration history, or a hand-written schema) — writing a
# second history for them would lie about who created what.
if [[ -f $app_root/db/schema.sql ]] && grep -q 'CREATE TABLE.*snails_queue_jobs' "$app_root/db/schema.sql"; then
  echo "[snails] job_queue tables already exist in db/schema.sql — no files written"
  exit 0
fi

version="$(date -u +%Y%m%d%H%M%S)"
mkdir -p "$app_root/db/migrate"
migration_rel="db/migrate/${version}_${migration_name}"
cp "$template" "$app_root/$migration_rel"

# One writer for both adapters: dump replays the migration files —
# sqlite into a temp file, pg into a throwaway schema on PG_URL.
if [[ $adapter == pg && -z ${PG_URL:-} ]]; then
  die 2 "no pg target: set PG_URL — generate regenerates the schema dump by replaying the migrations"
fi
bash "$GEN_SCRIPTS/migrate.sh" dump --app "$app_root"

echo "[snails] job_queue added: ${migration_rel} + db/schema.sql"
echo "next steps — in config/environment.rb:"
echo "  ActiveJob.queue_adapter = ActiveJob::DatabaseQueue"
echo "  # retention is off until you turn it on (finished rows accumulate):"
echo "  # ActiveJob.recurring(Snails::Queue::PruneJob, 86400)"
repair_arg="$(app_root_argument "$app_root")"
migrate_command="snails migrate apply"
[[ -n $repair_arg ]] && migrate_command+=" --app $(shell_quote "$repair_arg")"
echo "then apply the migration: $migrate_command"
