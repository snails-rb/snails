#!/bin/bash
# Regression test for `snails generate job_queue` (cli/generate.sh) — the
# stamp path for the DB-backed job queue.
#
# Cases: the sqlite run writes the migration (UTC version prefix) and
# regenerates the schema dump through `migrate dump` (one writer), the
# printed wiring carries the adapter line and the commented retention
# registration, a rerun is a one-line no-op, tables already in the
# schema dump write nothing, the pg app gets the `.pg` variant and the same
# dump/verify flow on a reachable server (dump replays into a
# throwaway schema on PG_URL), `migrate verify` proves the generated
# history reproduces the generated schema dump on both adapters, the
# surface refuses an unknown generator/flag, an unresolvable app root,
# and an ambiguous database configuration — and the engine runs without
# ruby. Skipped entirely when no postgres is reachable (not counted).
#
# Usage: bash scripts/test-generate-job-queue.sh
# Exit: 0=all cases pass, 1=failure.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLI="$ROOT/bin/snails"
TEMPLATE="$ROOT/scaffold/queue/create_snails_queue.sql"
TEMPLATE_PG="$ROOT/scaffold/queue/create_snails_queue.pg.sql"
# shellcheck source=pg-scratch.sh
source "$ROOT/scripts/pg-scratch.sh"

WORK="$(mktemp -d)"
if [[ ${KEEP_WORK:-} == 1 ]]; then
  trap 'echo "KEPT=$WORK"' EXIT
else
  trap 'rm -rf "$WORK"' EXIT
fi

pass=0
fail=0
chk() { # chk <name> <got> <want>
  if [[ $2 == "$3" ]]; then
    pass=$((pass + 1))
    echo "ok: $1"
  else
    fail=$((fail + 1))
    echo "FAIL: $1 (got '$2', want '$3')"
  fi
}
chk_has() { # chk_has <name> <haystack> <needle>
  if [[ $2 == *"$3"* ]]; then
    pass=$((pass + 1))
    echo "ok: $1"
  else
    fail=$((fail + 1))
    echo "FAIL: $1 (missing '$3' in: $2)"
  fi
}

# --- sqlite app fixture: just the database configuration the adapter
# detection reads (the generator writes the rest itself).
APP="$WORK/app"
mkdir -p "$APP/config"
printf 'APP_NAME="genq-fixture"\n' > "$APP/pins.toml"
printf 'require_relative "../snails-core/database/sqlite"\n' > "$APP/config/database.rb"

out="$("$CLI" generate job_queue "$APP" 2>&1)"; code=$?
chk "sqlite run exits 0" "$code" "0"
chk_has "result names both writes" "$out" "job_queue added: db/migrate/"
chk_has "result names the schema dump" "$out" "+ db/schema.sql"
chk_has "wiring prints the adapter line" "$out" "ActiveJob.queue_adapter = ActiveJob::DatabaseQueue"
chk_has "wiring prints retention commented out" "$out" "# ActiveJob.recurring(Snails::Queue::PruneJob, 86400)"
chk_has "wiring prints the apply step" "$out" "snails migrate apply --app"

migration="$(printf '%s\n' "$APP"/db/migrate/*_create_snails_queue.sql)"
chk "one migration was written" "$(printf '%s\n' "$APP"/db/migrate/*_create_snails_queue.sql | grep -c .)" "1"
chk "migration has a UTC timestamp version" "$(basename "$migration" | grep -c '^[0-9]\{14\}_create_snails_queue\.sql$')" "1"
chk "migration bytes are the shipped template" "$(cmp -s "$migration" "$TEMPLATE" && echo same || echo differ)" "same"
chk "schema dump carries the queue tables" "$(grep -c 'CREATE TABLE.*snails_queue_jobs\|CREATE TABLE.*snails_queue_occurrences' "$APP/db/schema.sql")" "2"

# The generated history must reproduce the generated schema dump — the
# schema contract's own gate over the generator's two writes.
out="$(cd "$WORK" && "$CLI" migrate verify --app "$APP" 2>&1)"; code=$?
chk "migrate verify agrees with the schema dump" "$code" "0"
chk_has "verify reports the agreement" "$out" "schema dump matches the migrate replay"

# --- rerun: one line, no second history.
before="$(ls "$APP/db/migrate" | wc -l | tr -d ' ')"
out="$("$CLI" generate job_queue "$APP" 2>&1)"; code=$?
chk "rerun exits 0" "$code" "0"
chk_has "rerun reports the existing migration" "$out" "job_queue migration already present"
chk "rerun writes no second migration" "$(ls "$APP/db/migrate" | wc -l | tr -d ' ')" "$before"

# --- tables already in the schema dump: the app owns its history.
SCHEMA_ONLY="$WORK/schema-only"
mkdir -p "$SCHEMA_ONLY/config" "$SCHEMA_ONLY/db"
printf 'require_relative "../snails-core/database/sqlite"\n' > "$SCHEMA_ONLY/config/database.rb"
cat "$TEMPLATE" > "$SCHEMA_ONLY/db/schema.sql"
out="$("$CLI" generate job_queue "$SCHEMA_ONLY" 2>&1)"; code=$?
chk "existing schema dump exits 0" "$code" "0"
chk_has "existing schema dump is a one-line result" "$out" "job_queue tables already exist in db/schema.sql — no files written"
chk "existing schema dump writes no migration" "$(ls "$SCHEMA_ONLY/db/migrate" 2>/dev/null | wc -l | tr -d ' ')" "0"

# --- pg app: the adapter's own DDL variant — and generate needs a
# reachable server: dump replays the migrations into a throwaway schema
# on it (PG_URL), then renders the schema dump with pg_dump.
if pg_scratch_available; then
  if ! pg_scratch_create "snails_generate_queue_test"; then
    echo "[test-generate-job-queue] could not create scratch database $PG_DB" >&2
    exit 1
  fi
  trap 'pg_scratch_drop' EXIT
  export PG_URL="$PG_TARGET"

  PGAPP="$WORK/pgapp"
  mkdir -p "$PGAPP/config"
  printf 'APP_NAME="genq-pg-fixture"\n' > "$PGAPP/pins.toml"
  printf 'require_relative "../snails-core/database/postgresql"\n' > "$PGAPP/config/database.rb"
  out="$("$CLI" generate job_queue "$PGAPP" 2>&1)"; code=$?
  chk "pg run exits 0" "$code" "0"
  pg_migration="$(printf '%s\n' "$PGAPP"/db/migrate/*_create_snails_queue.pg.sql)"
  chk "pg migration has the .pg adapter suffix" "$(printf '%s\n' "$PGAPP"/db/migrate/*_create_snails_queue.pg.sql | grep -c .)" "1"
  chk "pg migration bytes are the shipped template" "$(cmp -s "$pg_migration" "$TEMPLATE_PG" && echo same || echo differ)" "same"
  # pg_dump's rendering: the BIGSERIAL shorthand becomes an explicit
  # sequence plus the column default wired to it.
  chk "pg schema dump carries the sequence" "$(grep -c 'CREATE SEQUENCE snails_queue_jobs_id_seq' "$PGAPP/db/schema.sql")" "1"
  chk "pg schema dump wires the default to it" "$(grep -c "nextval('snails_queue_jobs_id_seq'" "$PGAPP/db/schema.sql")" "1"
  chk "pg schema dump carries no sqlite DDL" "$(grep -c 'AUTOINCREMENT' "$PGAPP/db/schema.sql")" "0"
  # The generated history must reproduce the generated schema dump — on pg
  # too (the same gate as the sqlite app below).
  out="$("$CLI" migrate verify --app "$PGAPP" 2>&1)"; code=$?
  chk "pg migrate verify agrees with the schema dump" "$code" "0"
  chk_has "pg verify reports the agreement" "$out" "schema dump matches"
else
  echo "skip: no postgres reachable at $PG_ADMIN (pg cases not counted)"
fi

# --- surface refusals (usage class: one line, exit 2).
out="$("$CLI" generate nope "$APP" 2>&1)"; code=$?
chk "unknown generator exits 2" "$code" "2"
chk_has "unknown generator names what exists" "$out" "unknown generator: nope — generators: job_queue"

out="$("$CLI" generate job_queue --bogus "$APP" 2>&1)"; code=$?
chk "unknown flag exits 2" "$code" "2"
chk_has "unknown flag prints the usage line" "$out" "usage: snails generate job_queue [<app_root>]"

out="$("$CLI" generate 2>&1)"; code=$?
chk "missing generator lists generators" "$code" "0"
chk_has "missing generator lists job_queue" "$out" "job_queue"

NO_ROOT="$WORK/outside"
mkdir -p "$NO_ROOT"
out="$(cd "$NO_ROOT" && "$CLI" generate job_queue 2>&1)"; code=$?
chk "unresolvable app root exits 2" "$code" "2"
chk_has "unresolvable app root points at the fix" "$out" "no app root at or above"

AMBIGUOUS="$WORK/ambiguous"
mkdir -p "$AMBIGUOUS/config"
printf 'require_relative "../snails-core/database/sqlite"\nrequire_relative "../snails-core/database/postgresql"\n' > "$AMBIGUOUS/config/database.rb"
out="$("$CLI" generate job_queue "$AMBIGUOUS" 2>&1)"; code=$?
chk "ambiguous database configuration exits 2" "$code" "2"
chk_has "ambiguous configuration names the rule" "$out" "must require exactly one adapter"

# --- the alias the short spelling buys.
ALIASAPP="$WORK/aliasapp"
mkdir -p "$ALIASAPP/config"
printf 'APP_NAME="genq-alias"\n' > "$ALIASAPP/pins.toml"
printf 'require_relative "../snails-core/database/sqlite"\n' > "$ALIASAPP/config/database.rb"
out="$("$CLI" g job_queue "$ALIASAPP" 2>&1)"; code=$?
chk "g alias runs the generator" "$code" "0"
chk_has "g alias writes the migration" "$out" "job_queue added: db/migrate/"

# --- ruby is never called (bash-only engine — the CLI must not need a
# ruby on PATH at all).
FAKEBIN="$WORK/fakebin"
mkdir -p "$FAKEBIN"
printf '#!/bin/bash\necho "ruby must not run" >&2\nexit 1\n' > "$FAKEBIN/ruby"
chmod +x "$FAKEBIN/ruby"
RUBYAPP="$WORK/rubyapp"
mkdir -p "$RUBYAPP/config"
printf 'APP_NAME="genq-rubyless"\n' > "$RUBYAPP/pins.toml"
printf 'require_relative "../snails-core/database/sqlite"\n' > "$RUBYAPP/config/database.rb"
out="$(PATH="$FAKEBIN:$PATH" "$CLI" generate job_queue "$RUBYAPP" 2>&1)"; code=$?
chk "generator runs without ruby" "$code" "0"

# --- the same template applied to the real PostgreSQL — the scratch
# database was created above (one per run); a run without a server
# skipped everything already.
if pg_scratch_available; then
  psql "$PG_TARGET" -q -v ON_ERROR_STOP=1 -f "$pg_migration" >/dev/null 2>&1; code=$?
  chk "pg template applies cleanly" "$code" "0"
  chk "pg queue table exists" "$(psql "$PG_TARGET" -tAc "SELECT count(*) FROM information_schema.tables WHERE table_name='snails_queue_jobs';")" "1"
  chk "pg ledger table exists" "$(psql "$PG_TARGET" -tAc "SELECT count(*) FROM information_schema.tables WHERE table_name='snails_queue_occurrences';")" "1"
  chk "pg prune index exists" "$(psql "$PG_TARGET" -tAc "SELECT count(*) FROM pg_indexes WHERE tablename='snails_queue_jobs' AND indexname='index_snails_queue_jobs_on_status_and_finished_at';")" "1"
  chk "pg jobs id is a sequence default" "$(psql "$PG_TARGET" -tAc "SELECT count(*) FROM information_schema.columns WHERE table_name='snails_queue_jobs' AND column_name='id' AND is_identity='YES' OR table_name='snails_queue_jobs' AND column_name='id' AND column_default LIKE 'nextval%';")" "1"
fi

echo "$pass passed, $fail failed"
if ((fail > 0)); then exit 1; fi
exit 0
