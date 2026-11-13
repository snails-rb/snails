#!/bin/bash
# Regression test for `snails migrate` (cli/migrate.sh) — the incremental
# half of the schema contract. Runs on sqlite by default; the pg cases run
# when a PostgreSQL server is reachable at PG_URL or the local default.
#
# Cases: pending/applied status, idempotent apply + ledger, `load` (fresh
# create/load/apply/dump, schema-only reload, existing-data preservation),
# plan writes nothing, adapter-file selection and not-applicable reporting,
# ambiguity and ledger-gap detection, the DB_OWNER=external refusal, `dump` (the schema dump
# writer: generated format, idempotent rerun, its guards — no history, no
# tables, --database, an unsupported object), the `verify` byte-compare
# gate (hand edit, forgotten dump, missing file, each with the dump
# repair), app-root resolution with --app omitted (walk up from inside the
# app; a repository root that holds the app in src/ resolves into it; a start
# above the app without that layout refuses with the fix), the check repair
# line (shortest path, shell quoting,
# --database preservation, unknown-option refusal), and version prefixes —
# a UTC timestamp version beside a 4-digit ordinal applied in numeric order,
# the adapter pair under a timestamp version, and the refusal for a file
# name with no version.
#
# Usage: bash scripts/test-migrate.sh
# Exit: 0=all cases pass, 1=failure.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLI="$ROOT/bin/snails"
ENGINE="$ROOT/cli/migrate.sh"
# shellcheck source=pg-scratch.sh
source "$ROOT/scripts/pg-scratch.sh"

WORK="$(mktemp -d)"
if [[ ${KEEP_WORK:-} == 1 ]]; then
  trap 'echo "KEPT=$WORK"' EXIT
else
  trap 'rm -rf "$WORK"' EXIT
fi

# The printed repair command names `snails`; this shim resolves that name to
# the checkout so the tests execute the command the developer sees.
mkdir -p "$WORK/bin"
ln -sf "$CLI" "$WORK/bin/snails"

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

# --- app fixture: migration files only. The schema dump they imply does not
# exist yet — `dump` below writes it, and `verify` compares against that
# output (one writer; the fixture never hand-writes a schema dump).
APP="$WORK/app"
mkdir -p "$APP/db/migrate" "$APP/config"
DB="$APP/storage/test.sqlite3"
mkdir -p "$APP/storage"

cat > "$APP/pins.toml" <<'PINS'
# fixture pins
APP_NAME="migrate-fixture"
PINS

# The database configuration boot requires — migrate reads the adapter from the same
# app-owned file the build follows.
cat > "$APP/config/database.rb" <<'RB'
require_relative "../snails-core/database/sqlite"
RB

cat > "$APP/db/migrate/0001_baseline.sql" <<'SQL'
CREATE TABLE IF NOT EXISTS widgets (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL,
  qty INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS index_widgets_on_name ON widgets (name);
SQL

cat > "$APP/db/migrate/0002_views.sql" <<'SQL'
DROP VIEW IF EXISTS widget_totals;
CREATE VIEW widget_totals AS
SELECT name, sum(qty) AS qty FROM widgets GROUP BY name;
SQL

migrate() { bash "$ENGINE" "$@" --app "$APP" --database "$DB"; }

# --- status on a database that does not exist yet: everything pending.
out=$(migrate status 2>&1); code=$?
chk "status exits 0 on a missing database" "$code" "0"
chk_has "status reports both pending" "$out" "0 applied, 2 pending"
chk "status summary is the first line" "$(printf '%s\n' "$out" | head -n1)" "[snails] 0 applied, 2 pending"
chk "status aligns the state column" "$(printf '%s\n' "$out" | awk '$0 !~ /^\[snails\]/ && / applied$| pending$/ { print index($0, $NF) }' | sort -u | wc -l | tr -d ' ')" "1"

# --- check on a missing database: every file is pending, and the gate must
# name the repair — but checking is read-only, so it must not create the file.
out=$(migrate check 2>&1); code=$?
chk "check exits 1 on a missing database with migrations" "$code" "1"
chk_has "check names the load repair" "$out" "snails migrate load"
chk "check does not create the database" "$([[ -f $DB ]] && echo yes || echo no)" "no"

# --- plan prints SQL and writes nothing (no database file created).
out=$(migrate plan 2>&1); code=$?
chk "plan exits 0" "$code" "0"
chk_has "plan prints the pending SQL" "$out" "CREATE VIEW widget_totals"
chk "plan does not create the database" "$([[ -f $DB ]] && echo yes || echo no)" "no"

# --- apply: ledger + objects; second run is a no-op. The per-file
# progress (`applying <label>`) prints on stderr; stdout is the summary.
out="$(migrate apply 2> "$WORK/apply.err")"; code=$?
chk "apply exits 0" "$code" "0"
chk_has "apply reports two applied" "$out" "2 applied"
chk "apply stdout is only the summary" "$out" "2 applied"
grep -q 'applying' "$WORK/apply.err"
chk "the per-file progress is on stderr" $? 0
if [[ $out == *applying* ]]; then apply_prog=1; else apply_prog=0; fi
chk "the stdout summary carries no progress" "$apply_prog" 0
chk "ledger has two rows" "$(sqlite3 "$DB" "SELECT count(*) FROM schema_migrations;")" "2"
chk "the view exists as a view" "$(sqlite3 "$DB" "SELECT type FROM sqlite_master WHERE name='widget_totals';")" "view"
chk "the index exists" "$(sqlite3 "$DB" "SELECT count(*) FROM sqlite_master WHERE name='index_widgets_on_name';")" "1"

out=$(migrate apply 2>&1); code=$?
chk "re-apply exits 0" "$code" "0"
chk_has "re-apply is a no-op" "$out" "nothing to apply"

out=$(migrate status 2>&1)
chk_has "status reports applied" "$out" "2 applied, 0 pending"

# --- check on a current database: silent success (the dev runner prints its
# own progress; a line per boot would be noise), and pending fails with one
# repair line while --verbose adds the labels.
out=$(migrate check 2>&1); code=$?
chk "check exits 0 on a current database" "$code" "0"
chk "check is silent on success" "$out" ""
sqlite3 "$DB" "DELETE FROM schema_migrations WHERE version='0002';"
out=$(migrate check 2>&1); code=$?
chk "check exits 1 with a pending migration" "$code" "1"
chk_has "check names the apply repair" "$out" "snails migrate apply"
chk "the pending check output is one line" "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "1"
if [[ $out == *0002_views* ]]; then listed=1; else listed=0; fi
chk "the default check output lists no migration labels" "$listed" "0"
out=$(migrate check --verbose 2>&1); code=$?
chk "verbose check still exits 1" "$code" "1"
chk_has "verbose check lists the pending label" "$out" "0002_views"
if [[ $(printf '%s\n' "$out" | head -n1) == "[snails] "*pending* ]]; then first_ok=1; else first_ok=0; fi
chk "verbose check keeps the repair line first" "$first_ok" "1"
migrate apply >/dev/null 2>&1
out=$(migrate check 2>&1); code=$?
chk "check passes after the repair" "$code" "0"

# --- the repair line renders for the current shell: omit --app at the app
# root, preserve an explicit --database, and keep the absolute form behind
# --verbose. The deep-directory case falls back to the absolute path because
# the relative form is longer.
sqlite3 "$DB" "DELETE FROM schema_migrations WHERE version='0002';"
out=$(cd "$APP" && bash "$ENGINE" check --database "$DB" 2>&1); code=$?
chk "repair from the app root exits 1" "$code" "1"
chk_has "repair from the app root omits --app" "$out" "run: snails migrate apply --database"
if [[ $out == *--app* ]]; then app_flag=1; else app_flag=0; fi
chk "repair from the app root carries no --app" "$app_flag" "0"
chk_has "repair preserves an explicit --database" "$out" "--database $DB"
out=$(cd "$APP" && bash "$ENGINE" check --database "$DB" --verbose 2>&1)
chk_has "verbose repair adds the full command" "$out" "full: snails migrate apply --app $APP --database $DB"
migrate apply >/dev/null 2>&1

# --- the deployment supplies the host-side repair command (the app image
# sets it): the value replaces the default, and the app argument is dropped
# because the container's /app is not a host path.
sqlite3 "$DB" "DELETE FROM schema_migrations WHERE version='0002';"
out=$(cd "$APP" && SNAILS_MIGRATE_REPAIR="bin/compose run --rm app snails migrate apply" bash "$ENGINE" check --database "$DB" 2>&1); code=$?
chk "the deployment repair exits 1" "$code" "1"
chk_has "the deployment repair is the supplied host command" "$out" "run: bin/compose run --rm app snails migrate apply --database $DB"
if [[ $out == *--app* ]]; then image_app=1; else image_app=0; fi
chk "the deployment repair carries no app argument" "$image_app" "0"
migrate apply >/dev/null 2>&1

deep="$APP"
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do deep="$deep/d$i"; done
mkdir -p "$deep"
sqlite3 "$DB" "DELETE FROM schema_migrations WHERE version='0002';"
out=$(cd "$deep" && bash "$ENGINE" check --app "$APP" --database "$DB" 2>&1); code=$?
chk "repair from a deep directory exits 1" "$code" "1"
# The repair prints whichever is shorter. The 12-level relative path wins on
# a long temp root (macOS `/var/folders/...`), while the absolute path wins
# on a short one (Linux `/tmp/...`); the contract is shortest, not absolute.
rel=""
for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do rel+="../"; done
rel="${rel%/}"
expected_app="$APP"
if (( ${#rel} <= ${#APP} )); then expected_app="$rel"; fi
chk_has "repair from a deep directory uses the shortest app path" "$out" "--app $expected_app"
migrate apply >/dev/null 2>&1
rm -rf "$deep"

# --- a symlinked working directory must not get a relative path: the kernel
# resolves `..` against the link target, so the printed path can point
# elsewhere.
mkdir -p "$WORK/nested"
ln -sfn "$APP" "$WORK/nested/link"
sqlite3 "$DB" "DELETE FROM schema_migrations WHERE version='0002';"
out=$(cd "$WORK/nested/link" && bash "$ENGINE" check --app "$APP" --database "$DB" 2>&1); code=$?
chk "symlinked-cwd repair exits 1" "$code" "1"
chk_has "symlinked-cwd repair uses the absolute app path" "$out" "--app $APP"
cmd="${out#*run: }"
(cd "$WORK/nested/link" && PATH="$WORK/bin:$PATH" eval "$cmd" >/dev/null 2>&1)
chk "the symlinked-cwd repair command runs" "$?" "0"
migrate apply >/dev/null 2>&1
rm -rf "$WORK/nested"

# --- external ownership: apply refuses, status stays available.
cp "$APP/pins.toml" "$WORK/pins.bak"
printf '\nDB_OWNER="external"\n' >> "$APP/pins.toml"
out=$(migrate status 2>&1); code=$?
chk "status works under external ownership" "$code" "0"
cp "$WORK/pins.bak" "$APP/pins.toml"
cp "$APP/pins.toml" "$WORK/pins.bak"
printf '\nDB_OWNER="external"\n' >> "$APP/pins.toml"
sqlite3 "$DB" "DELETE FROM schema_migrations WHERE version='0002';"
out=$(migrate apply 2>&1); code=$?
chk "apply refuses external ownership" "$code" "2"
chk_has "refusal names the ownership" "$out" "external"
chk "refused apply left the ledger alone" "$(sqlite3 "$DB" "SELECT count(*) FROM schema_migrations;")" "1"
out=$(migrate check 2>&1); code=$?
chk "check refuses pending under external ownership" "$code" "1"
chk_has "external check names the ownership" "$out" "external"
if [[ $out == *"snails migrate apply"* ]]; then instructed=1; else instructed=0; fi
chk "external check does not instruct apply" "$instructed" "0"
# The refusal is a declaration check: it must not depend on reaching the
# target first (an unreachable external target is still refused).
out=$(bash "$ENGINE" apply --app "$APP" --database "/nonexistent/never.sqlite3" 2>&1); code=$?
chk "refusal does not touch the target" "$code" "2"
chk_has "refusal is the ownership one" "$out" "external"
cp "$WORK/pins.bak" "$APP/pins.toml"
migrate apply >/dev/null 2>&1

# --- plan is a dry run: it reads the ledger when a target is resolvable
# (default path here), and says so when none is.
out=$(bash "$ENGINE" plan --app "$APP" 2>&1); code=$?
chk "plan works with the default target" "$code" "0"
chk_has "plan prints a pending migration" "$out" "-- 0002_views"

# --- the retired configuration name is still read: an app that has not bumped
# its core pin runs the old scaffold (its boot chain requires `config/db`), so the
# detector must resolve the same adapter from it — sync migrates the name.
LEGACY="$WORK/legacyapp"
cp -r "$APP" "$LEGACY"
rm -f "$LEGACY/config/database.rb"
printf 'require_relative "../runtime/db_sqlite"\n' > "$LEGACY/config/db.rb"
out=$(bash "$ENGINE" status --app "$LEGACY" --database "$LEGACY/storage/test.sqlite3" 2>&1); code=$?
chk "status resolves the adapter from a retired entry name" "$code" "0"
chk_has "the retired entry reads as the sqlite adapter" "$out" "2 applied"

# --- adapter files: a pg-only migration is not applicable; a paired one
# prefers the adapter file.
cat > "$APP/db/migrate/0003_pg_only.pg.sql" <<'SQL'
CREATE TABLE IF NOT EXISTS pg_only (id BIGSERIAL);
SQL
cat > "$APP/db/migrate/0004_paired.sql" <<'SQL'
CREATE TABLE IF NOT EXISTS paired (id INTEGER PRIMARY KEY, note TEXT);
SQL
cat > "$APP/db/migrate/0004_paired.sqlite.sql" <<'SQL'
CREATE TABLE IF NOT EXISTS paired (id INTEGER PRIMARY KEY);
SQL
out=$(migrate status 2>&1); code=$?
chk "status with adapter files exits 0" "$code" "0"
chk_has "pg-only file is reported not applicable" "$out" "0003_pg_only"
chk_has "pg-only file is marked n/a" "$out" "n/a (no sqlite file)"
migrate apply >/dev/null 2>&1
chk "pg-only migration was not applied" "$(sqlite3 "$DB" "SELECT count(*) FROM sqlite_master WHERE name='pg_only';")" "0"
chk "adapter file won over the common file" "$(sqlite3 "$DB" "SELECT count(*) FROM pragma_table_info('paired') WHERE name='note';")" "0"

# --- ambiguity: two names under one version.
APP2="$WORK/app2"
cp -r "$APP" "$APP2"
rm -f "$APP2/db/migrate/0003_pg_only.pg.sql" "$APP2/db/migrate/0004_paired.sql" "$APP2/db/migrate/0004_paired.sqlite.sql"
cat > "$APP2/db/migrate/0005_alpha.sql" <<'SQL'
CREATE TABLE IF NOT EXISTS alpha (id INTEGER PRIMARY KEY);
SQL
cat > "$APP2/db/migrate/0005_beta.sql" <<'SQL'
CREATE TABLE IF NOT EXISTS beta (id INTEGER PRIMARY KEY);
SQL
out=$(bash "$ENGINE" status --app "$APP2" --database "$APP2/storage/test.sqlite3" 2>&1); code=$?
chk "ambiguous version exits 1" "$code" "1"
chk_has "ambiguity names both files" "$out" "more than one name"

# --- ledger gap: a row whose file is gone.
sqlite3 "$DB" "INSERT INTO schema_migrations (version, applied_at) VALUES ('0099', '2026-01-01T00:00:00Z');"
out=$(migrate status 2>&1); code=$?
chk "ledger gap exits 1" "$code" "1"
chk_has "gap names the orphan version" "$out" "0099"
out=$(migrate check 2>&1); code=$?
chk "check refuses a ledger gap" "$code" "1"
chk_has "the check gap names the orphan version" "$out" "0099"
sqlite3 "$DB" "DELETE FROM schema_migrations WHERE version='0099';"

# --- dump: the schema dump writer. The fixture has no schema dump yet, so this
# is also the adoption run — then the guards that refuse to blank a
# hand-written tree, and the idempotent rerun.
out=$(bash "$ENGINE" dump --app "$APP" 2>&1); code=$?
chk "dump exits 0" "$code" "0"
chk_has "dump reports the regeneration" "$out" "schema dump regenerated"
chk_has "dump reports the statement count" "$out" "(4 statements)"
chk "the generated header names the writer" \
  "$(head -n 1 "$APP/db/schema.sql")" \
  "-- Generated by snails migrate dump from db/migrate/*.sql — do not edit."
chk "schema.sql keeps the tables idempotent" \
  "$(grep -c 'CREATE TABLE IF NOT EXISTS widgets' "$APP/db/schema.sql")" "1"
chk "schema.sql keeps the indexes idempotent" \
  "$(grep -c 'CREATE INDEX IF NOT EXISTS index_widgets_on_name' "$APP/db/schema.sql")" "1"
chk "the view lands in db/schema.sql" \
  "$(grep -c '^CREATE VIEW widget_totals' "$APP/db/schema.sql")" "1"
chk "dump writes no view files" "$([[ -d $APP/db/views ]] && echo yes || echo no)" "no"
chk "no stub table is generated for the view" \
  "$(grep -c 'CREATE TABLE.*widget_totals' "$APP/db/schema.sql")" "0"

before="$(cksum < "$APP/db/schema.sql")"
out=$(bash "$ENGINE" dump --app "$APP" 2>&1); code=$?
chk "a rerun dump exits 0" "$code" "0"
chk_has "a rerun dump reports no change" "$out" "schema dump is up to date"
chk "a rerun dump rewrites nothing" "$(cksum < "$APP/db/schema.sql")" "$before"

# --- dump guards: refuse before a hand-written tree can be blanked.
NOHIST="$WORK/nohist"
mkdir -p "$NOHIST/config" "$NOHIST/db"
printf 'APP_NAME="nohist"\n' > "$NOHIST/pins.toml"
printf 'require_relative "../snails-core/database/sqlite"\n' > "$NOHIST/config/database.rb"
printf 'CREATE TABLE hand_written (id INTEGER);\n' > "$NOHIST/db/schema.sql"
hand_sum="$(cksum < "$NOHIST/db/schema.sql")"
out=$(bash "$ENGINE" dump --app "$NOHIST" 2>&1); code=$?
chk "dump without migration files exits 2" "$code" "2"
chk_has "the empty-history refusal says why" "$out" "refusing to write an empty schema dump"
chk "the hand-written schema dump survived" "$(cksum < "$NOHIST/db/schema.sql")" "$hand_sum"

out=$(bash "$ENGINE" dump --app "$APP" --database "$DB" 2>&1); code=$?
chk "dump refuses --database" "$code" "2"
chk_has "--database refusal names the rule" "$out" "dump does not take --database"

DATAONLY="$WORK/dataonly"
mkdir -p "$DATAONLY/config" "$DATAONLY/db/migrate"
printf 'APP_NAME="dataonly"\n' > "$DATAONLY/pins.toml"
printf 'require_relative "../snails-core/database/sqlite"\n' > "$DATAONLY/config/database.rb"
printf 'CREATE TABLE scratch (id INTEGER);\nINSERT INTO scratch VALUES (1);\nDROP TABLE scratch;\n' > "$DATAONLY/db/migrate/0001_scratch.sql"
printf 'CREATE TABLE keep_me (id INTEGER);\n' > "$DATAONLY/db/schema.sql"
out=$(bash "$ENGINE" dump --app "$DATAONLY" 2>&1); code=$?
chk "dump with no tables left exits 2" "$code" "2"
chk_has "the empty-replay refusal says why" "$out" "the migrations create no tables"

# An object the schema dump format cannot express is refused, not silently
# dropped from the output — a schema dump missing the object would ship.
TRIGAPP="$WORK/triggerapp"
mkdir -p "$TRIGAPP/config" "$TRIGAPP/db/migrate"
printf 'APP_NAME="triggerapp"\n' > "$TRIGAPP/pins.toml"
printf 'require_relative "../snails-core/database/sqlite"\n' > "$TRIGAPP/config/database.rb"
printf 'CREATE TABLE trig_t (id INTEGER);\nCREATE TRIGGER trig_t_ai AFTER INSERT ON trig_t BEGIN SELECT 1; END;\n' > "$TRIGAPP/db/migrate/0001_trig.sql"
out=$(bash "$ENGINE" dump --app "$TRIGAPP" 2>&1); code=$?
chk "dump refuses an unsupported object" "$code" "2"
chk_has "the refusal names the object" "$out" "unsupported object in the migrations: trigger trig_t"

# --- verify: byte-compare the committed schema dump against `dump`'s output.
out=$(migrate verify 2>&1); code=$?
chk "verify exits 0 when the schema dump is dump's output" "$code" "0"
chk_has "verify reports the statement count" "$out" "schema dump matches"

# A hand edit — the failure the generated-output rule exists for.
cp "$APP/db/schema.sql" "$WORK/schema.bak"
printf '\n-- hand-written note\n' >> "$APP/db/schema.sql"
out=$(migrate verify 2>&1); code=$?
chk "verify catches a hand-edited schema dump" "$code" "1"
chk_has "the hand edit names its file" "$out" "db/schema.sql: differs"
chk_has "the repair is dump" "$out" "run: snails migrate dump"
out=$(migrate verify --verbose 2>&1); code=$?
chk "verbose verify still exits 1" "$code" "1"
chk_has "verbose verify shows the differing lines" "$out" "hand-written note"
cp "$WORK/schema.bak" "$APP/db/schema.sql"

# A migration added without a dump, and the repair line it hands back.
cat > "$APP/db/migrate/0006_extra.sql" <<'SQL'
CREATE TABLE IF NOT EXISTS extra (id INTEGER PRIMARY KEY);
SQL
out=$(migrate verify 2>&1); code=$?
chk "verify catches a forgotten dump" "$code" "1"
chk_has "the forgotten dump names schema.sql" "$out" "db/schema.sql: differs"
repair_line="$(printf '%s\n' "$out" | awk '/run: / { print; exit }')"
cmd="${repair_line#*run: }"
(cd "$WORK" && PATH="$WORK/bin:$PATH" eval "$cmd" >/dev/null 2>&1)
chk "the printed repair command runs" "$?" "0"
out=$(migrate verify 2>&1); code=$?
chk "verify passes after the repair" "$code" "0"
rm -f "$APP/db/migrate/0006_extra.sql"
out=$(bash "$ENGINE" dump --app "$APP" 2>&1); code=$?
chk "dump follows the removed migration" "$code" "0"
chk "the extra table left the schema dump" "$(grep -c 'CREATE TABLE.*extra' "$APP/db/schema.sql")" "0"

# A missing schema dump is drift too (repair: dump writes it back).
mv "$APP/db/schema.sql" "$WORK/schema.bak"
out=$(migrate verify 2>&1); code=$?
chk "verify catches a missing schema dump" "$code" "1"
chk_has "the missing schema dump names the file" "$out" "db/schema.sql: missing"
out=$(bash "$ENGINE" dump --app "$APP" 2>&1); code=$?
chk "dump restores the missing schema dump" "$code" "0"

# db/views is not the schema dump's business: the loader reads db/schema.sql
# only, and a stray view file belongs to the developer's manual upgrade —
# dump and verify leave it untouched.
mkdir -p "$APP/db/views"
printf 'CREATE VIEW stale AS SELECT 1;\n' > "$APP/db/views/stale.sql"
out=$(migrate verify 2>&1); code=$?
chk "verify ignores a stray db/views file" "$code" "0"
out=$(bash "$ENGINE" dump --app "$APP" 2>&1); code=$?
chk "dump exits 0 with a stray db/views file" "$code" "0"
chk "dump leaves the stray view file alone" "$([[ -f $APP/db/views/stale.sql ]] && echo yes || echo no)" "yes"
rm -f "$APP/db/views/stale.sql"
rmdir "$APP/db/views"

# --- CLI wiring: the subcommand reaches the engine.
out=$("$CLI" migrate status --app "$APP" --database "$DB" 2>&1); code=$?
chk "cli migrate status exits 0" "$code" "0"
chk_has "cli migrate status reports applied" "$out" "applied"
out=$("$CLI" migrate check --app "$APP" --database "$DB" 2>&1); code=$?
chk "cli migrate check passes on a current database" "$code" "0"

# --- no interpreter beyond the adapter's own client: with a `ruby` that fails
# loudly shadowed on PATH, the whole CLI path must still work (the engine
# must never call one).
NORUBY="$WORK/noruby"
mkdir -p "$NORUBY"
cat > "$NORUBY/ruby" <<'SH'
#!/bin/bash
echo "ruby must not be called by the migrate engine" >&2
exit 127
SH
chmod +x "$NORUBY/ruby"
out=$(PATH="$NORUBY:$PATH" "$CLI" migrate status --app "$APP" --database "$DB" 2>&1); code=$?
chk "cli migrate runs with ruby shadowed" "$code" "0"
chk_has "shadowed run still prints the ledger state" "$out" "applied"
out=$(PATH="$NORUBY:$PATH" "$CLI" migrate verify --app "$APP" --database "$DB" 2>&1); code=$?
chk "cli migrate verify runs with ruby shadowed" "$code" "0"
chk_has "the ruby shadow was never reached" "$out" "schema dump matches"
out=$(PATH="$NORUBY:$PATH" "$CLI" migrate dump --app "$APP" 2>&1); code=$?
chk "cli migrate dump runs with ruby shadowed" "$code" "0"
chk_has "dump with ruby shadowed reports the state" "$out" "schema dump is up to date"

# --- default target: no --database resolves to <app>/storage/development.sqlite3.
rm -f "$APP/storage/development.sqlite3"
out=$(bash "$ENGINE" apply --app "$APP" 2>&1); code=$?
chk "default target apply exits 0" "$code" "0"
chk "default target file created" "$([[ -f $APP/storage/development.sqlite3 ]] && echo yes || echo no)" "yes"

# --- a fresh clone has no storage/ (it is gitignored): apply creates the
# target's parent directory, while the read-only commands still write nothing.
FRESH="$WORK/fresh"
mkdir -p "$FRESH/db/migrate" "$FRESH/config"
cat > "$FRESH/pins.toml" <<'PINS'
APP_NAME="fresh-fixture"
PINS
cat > "$FRESH/config/database.rb" <<'RB'
require_relative "../snails-core/database/sqlite"
RB
cat > "$FRESH/db/migrate/0001_baseline.sql" <<'SQL'
CREATE TABLE IF NOT EXISTS fresh_app (id INTEGER PRIMARY KEY);
SQL
out=$(bash "$ENGINE" status --app "$FRESH" 2>&1); code=$?
chk "status on a missing storage dir exits 0" "$code" "0"
chk "status does not create storage" "$([[ -d $FRESH/storage ]] && echo yes || echo no)" "no"
out=$(bash "$ENGINE" apply --app "$FRESH" 2>&1); code=$?
chk "apply on a missing storage dir exits 0" "$code" "0"
chk "apply creates the sqlite storage dir" "$([[ -d $FRESH/storage ]] && echo yes || echo no)" "yes"
chk "apply creates the default database file" "$([[ -f $FRESH/storage/development.sqlite3 ]] && echo yes || echo no)" "yes"

# --- load: the explicit initialization command. A fresh target loads the
# schema dump, replays the migrations into the ledger, and refreshes the
# schema dump. An initialized target skips the schema dump load and applies only
# new migrations.
LOAD="$WORK/load"
mkdir -p "$LOAD/db/migrate" "$LOAD/config"
cat > "$LOAD/pins.toml" <<'PINS'
APP_NAME="load-fixture"
PINS
cat > "$LOAD/config/database.rb" <<'RB'
require_relative "../snails-core/database/sqlite"
RB
cat > "$LOAD/db/migrate/0001_baseline.sql" <<'SQL'
CREATE TABLE IF NOT EXISTS load_items (id INTEGER PRIMARY KEY, name TEXT);
SQL
LOAD_DB="$LOAD/storage/load.sqlite3"
bash "$ENGINE" dump --app "$LOAD" >/dev/null
schema_dump_before="$(cksum < "$LOAD/db/schema.sql")"

out=$(bash "$ENGINE" check --app "$LOAD" --database "$LOAD_DB" 2>&1); code=$?
chk "check on an uninitialized database exits 1" "$code" "1"
chk_has "check names the load repair" "$out" "snails migrate load"
chk "check does not create the load database" "$([[ -f $LOAD_DB ]] && echo yes || echo no)" "no"

out=$(bash "$ENGINE" load --app "$LOAD" --database "$LOAD_DB" 2>&1); code=$?
chk "load exits 0" "$code" "0"
chk_has "load reports the ready database" "$out" "database ready"
chk "load created the database" "$([[ -f $LOAD_DB ]] && echo yes || echo no)" "yes"
chk "load created the table from the schema dump" "$(sqlite3 "$LOAD_DB" "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='load_items';")" "1"
chk "load recorded the ledger" "$(sqlite3 "$LOAD_DB" "SELECT count(*) FROM schema_migrations;")" "1"
bash "$ENGINE" verify --app "$LOAD" --database "$LOAD_DB" >/dev/null 2>&1
chk "load keeps the schema dump in step" "$?" "0"

sqlite3 "$LOAD_DB" "INSERT INTO load_items (name) VALUES ('kept');"
out=$(bash "$ENGINE" load --app "$LOAD" --database "$LOAD_DB" 2>&1); code=$?
chk "a second load exits 0" "$code" "0"
chk "a second load keeps the data" "$(sqlite3 "$LOAD_DB" "SELECT name FROM load_items;")" "kept"
chk "the second load keeps the schema dump byte-identical" "$(cksum < "$LOAD/db/schema.sql")" "$schema_dump_before"

printf 'CREATE TABLE IF NOT EXISTS load_extra (id INTEGER PRIMARY KEY);\n' > "$LOAD/db/migrate/0002_extra.sql"
out=$(bash "$ENGINE" check --app "$LOAD" --database "$LOAD_DB" 2>&1); code=$?
chk "check on an initialized database with pending exits 1" "$code" "1"
chk_has "an initialized database names the apply repair" "$out" "snails migrate apply"
out=$(bash "$ENGINE" load --app "$LOAD" --database "$LOAD_DB" 2>&1); code=$?
chk "load applies the new migration" "$code" "0"
chk "the new table exists" "$(sqlite3 "$LOAD_DB" "SELECT count(*) FROM sqlite_master WHERE name='load_extra';")" "1"
chk "load refreshed the schema dump" "$(grep -c 'CREATE TABLE IF NOT EXISTS load_extra' "$LOAD/db/schema.sql")" "1"
chk "load kept the earlier row" "$(sqlite3 "$LOAD_DB" "SELECT name FROM load_items;")" "kept"

# --- a schema-only app (no migration files) still needs the explicit load:
# the schema dump is the only way to create its tables.
SCHEMA_ONLY="$WORK/schema-only"
mkdir -p "$SCHEMA_ONLY/db" "$SCHEMA_ONLY/config"
cat > "$SCHEMA_ONLY/pins.toml" <<'PINS'
APP_NAME="schema-only-fixture"
PINS
cat > "$SCHEMA_ONLY/config/database.rb" <<'RB'
require_relative "../snails-core/database/sqlite"
RB
cat > "$SCHEMA_ONLY/db/schema.sql" <<'SQL'
CREATE TABLE IF NOT EXISTS schema_items (id INTEGER PRIMARY KEY);
SQL
SCHEMA_DB="$SCHEMA_ONLY/storage/schema.sqlite3"
out=$(bash "$ENGINE" check --app "$SCHEMA_ONLY" --database "$SCHEMA_DB" 2>&1); code=$?
chk "check on an uninitialized schema-only app exits 1" "$code" "1"
chk_has "the schema-only check names the load repair" "$out" "snails migrate load"
out=$(bash "$ENGINE" load --app "$SCHEMA_ONLY" --database "$SCHEMA_DB" 2>&1); code=$?
chk "schema-only load exits 0" "$code" "0"
chk "schema-only load created the table" "$(sqlite3 "$SCHEMA_DB" "SELECT count(*) FROM sqlite_master WHERE name='schema_items';")" "1"
chk "schema-only load created the ledger marker" "$(sqlite3 "$SCHEMA_DB" "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='schema_migrations';")" "1"
out=$(bash "$ENGINE" check --app "$SCHEMA_ONLY" --database "$SCHEMA_DB" 2>&1); code=$?
chk "the schema-only check passes after load" "$code" "0"
printf 'CREATE TABLE IF NOT EXISTS schema_extra (id INTEGER PRIMARY KEY);\n' >> "$SCHEMA_ONLY/db/schema.sql"
out=$(bash "$ENGINE" load --app "$SCHEMA_ONLY" --database "$SCHEMA_DB" 2>&1); code=$?
chk "a schema-only reload exits 0" "$code" "0"
chk "a schema-only reload applies the changed schema dump" "$(sqlite3 "$SCHEMA_DB" "SELECT count(*) FROM sqlite_master WHERE name='schema_extra';")" "1"

# --- nothing to initialize: no schema dump and no migration files.
EMPTY="$WORK/empty"
mkdir -p "$EMPTY/config"
cat > "$EMPTY/pins.toml" <<'PINS'
APP_NAME="empty-fixture"
PINS
cat > "$EMPTY/config/database.rb" <<'RB'
require_relative "../snails-core/database/sqlite"
RB
EMPTY_DB="$EMPTY/storage/empty.sqlite3"
out=$(bash "$ENGINE" load --app "$EMPTY" --database "$EMPTY_DB" 2>&1); code=$?
chk "load with nothing to initialize exits 0" "$code" "0"
chk_has "load with nothing reports it" "$out" "nothing to load"
chk "load with nothing creates no database" "$([[ -f $EMPTY_DB ]] && echo yes || echo no)" "no"

# --- app root resolution: with --app omitted the walk starts at $PWD and
# takes the nearest database configuration at or above. Moving off $PWD is announced; standing outside any
# app root refuses with the fix. A repository root that holds the app in the
# standard src/ layout resolves into src/.
out=$(cd "$APP/storage" && bash "$ENGINE" status 2> "$WORK/walk.err"); code=$?
chk "status from a subdirectory exits 0" "$code" "0"
chk_has "the walk announces the resolved app root" "$(cat "$WORK/walk.err")" "app root $APP (auto-resolved)"
chk_has "the subdirectory run reads the app's ledger" "$out" "applied"

out=$(cd "$APP" && bash "$ENGINE" status 2> "$WORK/root.err"); code=$?
chk "status from the app root exits 0" "$code" "0"
chk "no announcement when cwd is the app root" "$(grep -c 'auto-resolved' "$WORK/root.err")" "0"

mkdir -p "$WORK/repo/.git"
cp -R "$APP" "$WORK/repo/src"
out=$(cd "$WORK/repo" && bash "$ENGINE" status --database "$WORK/repo/src/storage/test.sqlite3" 2> "$WORK/repo.err"); code=$?
chk "status from the repository root resolves the src/ app" "$code" "0"
chk_has "the src/ resolution is announced" "$(cat "$WORK/repo.err")" "app root $WORK/repo/src (auto-resolved)"
chk_has "the repository-root run reads the app's ledger" "$out" "applied"

out=$(cd "$WORK" && bash "$ENGINE" status 2>&1); code=$?
chk "status outside any app root exits 2" "$code" "2"
chk_has "the refusal names the fix" "$out" "pass --app"

out=$(bash "$ENGINE" status --app "$WORK/missing" 2>&1); code=$?
chk "a missing --app exits 2" "$code" "2"
chk_has "the missing --app message keeps the path" "$out" "no such app directory: $WORK/missing"

out=$(cd "$APP/storage" && "$CLI" migrate status 2>&1); code=$?
chk "cli migrate resolves from a subdirectory" "$code" "0"
chk_has "cli migrate from a subdirectory reports the ledger" "$out" "applied"

# --- outside the app: the pins file lives at the app root, so the
# parent directory above it does not resolve — it refuses with the fix
# instead of scanning below for an app. The standard src/ layout resolves
# only at the repository root (the directory carrying .git).
PROJECT="$WORK/project"
mkdir -p "$PROJECT/src/db/migrate" "$PROJECT/src/config" "$PROJECT/src/storage"
cat > "$PROJECT/src/pins.toml" <<'PINS'
APP_NAME="project-fixture"
PINS
cat > "$PROJECT/src/config/database.rb" <<'RB'
require_relative "../snails-core/database/sqlite"
RB
cat > "$PROJECT/src/db/migrate/0001_baseline.sql" <<'SQL'
CREATE TABLE IF NOT EXISTS things (id INTEGER PRIMARY KEY);
SQL

out=$(cd "$PROJECT" && bash "$ENGINE" apply 2>&1); code=$?
chk "a parent directory above the app refuses" "$code" "2"
chk_has "the refusal names the fix" "$out" "pass --app DIR"

# --- the repair line comes from inside the app: a subdirectory start
# resolves, and the printed command is the shortest path back.
cat > "$PROJECT/src/db/migrate/0002_pending.sql" <<'SQL'
CREATE TABLE IF NOT EXISTS pending_things (id INTEGER PRIMARY KEY);
SQL
out=$(cd "$PROJECT/src/storage" && bash "$ENGINE" check 2>&1); code=$?
chk "check from a subdirectory resolves and finds the pending file" "$code" "1"
repair_line="$(printf '%s\n' "$out" | awk '/run: / { print; exit }')"
chk_has "the repair uses the shortest relative app path" "$repair_line" "run: snails migrate load --app .."
if [[ $repair_line == *"$PROJECT"* ]]; then project_abs=1; else project_abs=0; fi
chk "the repair carries no absolute app path" "$project_abs" "0"
cmd="${repair_line#*run: }"
(cd "$PROJECT/src/storage" && PATH="$WORK/bin:$PATH" eval "$cmd" >/dev/null 2>&1)
chk "the printed command runs from that directory" "$?" "0"
chk "the repair targets the app's default database" "$([[ -f $PROJECT/src/storage/development.sqlite3 ]] && echo yes || echo no)" "yes"
sqlite3 "$PROJECT/src/storage/development.sqlite3" "DELETE FROM schema_migrations WHERE version='0002';"
rm -f "$PROJECT/src/db/migrate/0002_pending.sql"

# --- a path with a space, a single quote, and a shell metacharacter must be
# quoted in the printed command, and the command must run from the
# directory that saw the check.
SPACE_APP="$WORK/app's & space"
mkdir -p "$SPACE_APP/config" "$SPACE_APP/db/migrate" "$SPACE_APP/storage"
cp "$APP/config/database.rb" "$SPACE_APP/config/database.rb"
printf 'APP_NAME="space-fixture"\n' > "$SPACE_APP/pins.toml"
cat > "$SPACE_APP/db/migrate/0001_space.sql" <<'SQL'
CREATE TABLE IF NOT EXISTS space_widgets (id INTEGER PRIMARY KEY);
SQL
out=$(cd "$WORK" && bash "$ENGINE" check --app "$SPACE_APP" 2>&1); code=$?
chk "special-path check exits 1" "$code" "1"
chk_has "special-path repair quotes the app path" "$out" "--app 'app'\\''s & space'"
cmd="${out#*run: }"
(cd "$WORK" && PATH="$WORK/bin:$PATH" eval "$cmd" >/dev/null 2>&1)
chk "the printed special-path command runs" "$?" "0"

# --- an unknown option is refused by the generic parser; a removed option
# leaves no special case behind.
out=$(bash "$ENGINE" status --bogus 2>&1); code=$?
chk "an unknown option is refused" "$code" "2"
chk_has "the refusal names the option" "$out" "unknown option: --bogus"

# --- a pins file above the app is not a resolution: the repository root
# refuses whatever sits below it — no scan looks for an app to guess with.
mkdir -p "$PROJECT/second/config"
cp "$PROJECT/src/config/database.rb" "$PROJECT/second/config/database.rb"
out=$(cd "$PROJECT" && bash "$ENGINE" status 2>&1); code=$?
chk "the repository root refuses whatever is below it" "$code" "2"
chk_has "the refusal names the fix" "$out" "pass --app DIR"
rm -rf "$PROJECT/second"

PROJECT2="$WORK/project-noapp"
mkdir -p "$PROJECT2"
printf 'APP_NAME="noapp"\n' > "$PROJECT2/pins.toml"
out=$(cd "$PROJECT2" && bash "$ENGINE" status 2>&1); code=$?
chk "a directory with pins but no app root refuses" "$code" "2"
chk_has "the refusal names what it looked for" "$out" "no app root at or above $PROJECT2"

# --- version prefixes: the format new migrations carry (a UTC timestamp)
# and the ordering contract (ascending NUMERIC version, not the shell's
# collation). The fixture mixes a short ordinal with two timestamps where
# the two orders disagree: as text "2100_" sorts AFTER "20261026120000_",
# as numbers it comes first — ordinal files are always the older ones.
MIXAPP="$WORK/mixapp"
mkdir -p "$MIXAPP/db/migrate" "$MIXAPP/config" "$MIXAPP/storage"
cat > "$MIXAPP/pins.toml" <<'PINS'
APP_NAME="version-fixture"
PINS
cat > "$MIXAPP/config/database.rb" <<'RB'
require_relative "../snails-core/database/sqlite"
RB

cat > "$MIXAPP/db/migrate/2100_legacy.sql" <<'SQL'
CREATE TABLE IF NOT EXISTS mix_legacy (id INTEGER PRIMARY KEY);
SQL
cat > "$MIXAPP/db/migrate/20261026120000_first.sql" <<'SQL'
CREATE TABLE IF NOT EXISTS mix_first (id INTEGER PRIMARY KEY);
SQL
cat > "$MIXAPP/db/migrate/20261026120001_second.sql" <<'SQL'
CREATE TABLE IF NOT EXISTS mix_second (id INTEGER PRIMARY KEY);
SQL

mixmigrate() { bash "$ENGINE" "$@" --app "$MIXAPP" --database "$MIXAPP/storage/test.sqlite3"; }

out=$(mixmigrate plan 2>&1); code=$?
chk "timestamp-version plan exits 0" "$code" "0"
chk "plan orders by numeric version (ordinal first)" \
  "$(printf '%s\n' "$out" | sed -n 's/^-- \([^ ]*\).*/\1/p' | tr '\n' ' ')" \
  "2100_legacy 20261026120000_first 20261026120001_second "

out="$(mixmigrate apply 2> "$WORK/mix.err")"; code=$?
chk "timestamp-version apply exits 0" "$code" "0"
chk_has "apply reports three applied" "$out" "3 applied"
chk "apply runs in the same numeric order" \
  "$(sed -n 's/^applying \([^ ]*\).*/\1/p' "$WORK/mix.err" | tr '\n' ' ')" \
  "2100_legacy 20261026120000_first 20261026120001_second "
chk "the ledger stores the full timestamp versions" \
  "$(sqlite3 "$MIXAPP/storage/test.sqlite3" "SELECT count(*) FROM schema_migrations WHERE version IN ('20261026120000', '20261026120001');")" "2"
chk "the ledger keeps the ordinal version" \
  "$(sqlite3 "$MIXAPP/storage/test.sqlite3" "SELECT count(*) FROM schema_migrations WHERE version = '2100';")" "1"
chk "all three tables exist" \
  "$(sqlite3 "$MIXAPP/storage/test.sqlite3" "SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name IN ('mix_legacy', 'mix_first', 'mix_second');")" "3"

out=$(mixmigrate apply 2>&1); code=$?
chk "re-apply of a mixed tree exits 0" "$code" "0"
chk_has "re-apply of a mixed tree is a no-op" "$out" "nothing to apply"

# --- the adapter pair groups under a timestamp version exactly as it does
# under an ordinal one: the common file and the adapter file are ONE
# version, and the adapter file wins.
cat > "$MIXAPP/db/migrate/20261026120002_paired.sql" <<'SQL'
CREATE TABLE IF NOT EXISTS mix_paired (id INTEGER PRIMARY KEY, note TEXT);
SQL
cat > "$MIXAPP/db/migrate/20261026120002_paired.sqlite.sql" <<'SQL'
CREATE TABLE IF NOT EXISTS mix_paired (id INTEGER PRIMARY KEY);
SQL
out=$(mixmigrate status 2>&1); code=$?
chk "status with a timestamp pair exits 0" "$code" "0"
chk "the pair is one version line" "$(printf '%s\n' "$out" | grep -c '^20261026120002_paired')" "1"
chk "the pair line shows its pending state" "$(printf '%s\n' "$out" | grep -cE '^20261026120002_paired +pending$')" "1"
mixmigrate apply >/dev/null 2>&1
chk "the adapter file won under the timestamp version" \
  "$(sqlite3 "$MIXAPP/storage/test.sqlite3" "SELECT count(*) FROM pragma_table_info('mix_paired') WHERE name = 'note';")" "0"

# --- a file with no version is refused, and the refusal says what a
# version looks like and how to make one.
cat > "$MIXAPP/db/migrate/add_widgets.sql" <<'SQL'
CREATE TABLE IF NOT EXISTS mix_bad (id INTEGER PRIMARY KEY);
SQL
out=$(mixmigrate status 2>&1); code=$?
chk "a file without a version exits 1" "$code" "1"
chk_has "the refusal names the expected shape" "$out" "expected <version>_<name>"
chk_has "the refusal shows how to make a version" "$out" "date -u +%Y%m%d%H%M%S"
rm -f "$MIXAPP/db/migrate/add_widgets.sql"

# --- pg adapter: the same commands and file format against a real server.
# Skipped (not counted) when no postgres is reachable — CI provides one.
if pg_scratch_available; then
  if ! pg_scratch_create "snails_migrate_test"; then
    echo "[test-migrate] could not create scratch database $PG_DB" >&2
    exit 1
  fi
  # Replace the work-only trap: a scratch database must not survive a
  # failure mid-section (CI runners are ephemeral, dev machines are not).
  trap 'pg_scratch_drop; rm -rf "$WORK"' EXIT

  PGAPP="$WORK/pgapp"
  mkdir -p "$PGAPP/db/migrate" "$PGAPP/config"
  cat > "$PGAPP/config/database.rb" <<'RB'
require_relative "../snails-core/database/postgresql"
RB
  cat > "$PGAPP/pins.toml" <<'PINS'
APP_NAME="migrate-fixture-pg"
PINS
  cat > "$PGAPP/db/migrate/0001_baseline.sql" <<'SQL'
CREATE TABLE IF NOT EXISTS widgets (
  id BIGSERIAL PRIMARY KEY,
  name TEXT NOT NULL,
  qty INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS index_widgets_on_name ON widgets (name);
SQL
  cat > "$PGAPP/db/migrate/0002_views.sql" <<'SQL'
DROP VIEW IF EXISTS widget_totals;
CREATE VIEW widget_totals AS
SELECT name, sum(qty) AS qty FROM widgets GROUP BY name;
SQL
  cat > "$PGAPP/db/migrate/0003_pg_only.pg.sql" <<'SQL'
CREATE TABLE IF NOT EXISTS other (id BIGSERIAL PRIMARY KEY);
SQL
  cat > "$PGAPP/db/migrate/0004_sqlite_only.sqlite.sql" <<'SQL'
CREATE TABLE IF NOT EXISTS sqlite_only (id INTEGER PRIMARY KEY);
SQL

  pgmigrate() { bash "$ENGINE" "$@" --app "$PGAPP" --database "$PG_TARGET"; }

  # A dry run with nothing resolvable: PG_URL unset and no --database. With no
  # target the ledger cannot be read, so every applicable migration is listed
  # and none is filtered out as already applied. The notice should name that
  # cause; its remaining wording is not part of the contract.
  out=$(env -u PG_URL bash "$ENGINE" plan --app "$PGAPP" 2>&1); code=$?
  chk "pg plan without a target exits 0" "$code" "0"
  chk_has "pg plan without a target names the cause" "$out" "no target resolved"
  missing=""
  for version in 0001_baseline 0002_views 0003_pg_only; do
    [[ $out == *"$version"* ]] || missing+=" $version"
  done
  chk "pg plan without a target lists every applicable migration" "$missing" ""
  [[ $out == *0004_sqlite_only* ]]
  chk "pg plan without a target skips the sqlite-only file" "$?" "1"

  out=$(pgmigrate status 2>&1); code=$?
  chk "pg status exits 0" "$code" "0"
  chk_has "pg status reports pending" "$out" "0 applied, 3 pending"
  chk_has "pg status marks the sqlite-only file n/a" "$out" "n/a (no pg file)"

  out=$(pgmigrate apply 2>&1); code=$?
  chk "pg apply exits 0" "$code" "0"
  chk "pg ledger has three rows" "$(psql "$PG_TARGET" -tAc "SELECT count(*) FROM schema_migrations;")" "3"
  chk "pg view exists" "$(psql "$PG_TARGET" -tAc "SELECT count(*) FROM information_schema.views WHERE table_name='widget_totals';")" "1"
  chk "pg adapter file was applied" "$(psql "$PG_TARGET" -tAc "SELECT count(*) FROM information_schema.tables WHERE table_name='other';")" "1"

  out=$(pgmigrate apply 2>&1); code=$?
  chk_has "pg re-apply is a no-op" "$out" "nothing to apply"

  # external ownership: apply refuses on the declaration alone, and so do
  # the commands that would WRITE a throwaway schema to the target. sqlite
  # dump/verify never touch the target and stay available.
  cp "$PGAPP/pins.toml" "$WORK/pgpins.bak"
  printf '\nDB_OWNER="external"\n' >> "$PGAPP/pins.toml"
  psql "$PG_TARGET" -q -c "DELETE FROM schema_migrations WHERE version='0002';" >/dev/null 2>&1
  out=$(pgmigrate apply 2>&1); code=$?
  chk "pg apply refuses external ownership" "$code" "2"
  chk "pg refused apply left the ledger alone" "$(psql "$PG_TARGET" -tAc "SELECT count(*) FROM schema_migrations;")" "2"
  # The external-owner shape: an external owner and a target that is NOT
  # reachable still refuses on the declaration alone.
  out=$(bash "$ENGINE" apply --app "$PGAPP" --database "postgres://nobody@127.0.0.1:1/never" 2>&1); code=$?
  chk "pg refusal needs no reachable server" "$code" "2"
  chk_has "pg refusal is the ownership one" "$out" "external"
  out=$(pgmigrate dump 2>&1); code=$?
  chk "pg dump refuses external ownership" "$code" "2"
  chk_has "pg dump refusal names the ownership" "$out" "external"
  out=$(pgmigrate verify 2>&1); code=$?
  chk "pg verify refuses external ownership" "$code" "2"
  chk_has "pg verify refusal names the ownership" "$out" "external"
  cp "$WORK/pgpins.bak" "$PGAPP/pins.toml"

  # Without a target there is no scratch pad for the replay (sqlite dump
  # needs no target at all — it reads the migration files).
  out=$(env -u PG_URL bash "$ENGINE" dump --app "$PGAPP" 2>&1); code=$?
  chk "pg dump without a target exits 2" "$code" "2"
  chk_has "the target refusal names the fix" "$out" "no pg target"

  # dump: the schema dump comes from the files, rendered through pg_dump.
  out=$(pgmigrate dump 2>&1); code=$?
  chk "pg dump exits 0" "$code" "0"
  chk_has "pg dump reports the regeneration" "$out" "schema dump regenerated"
  chk "pg schema dump carries the table" "$(grep -c 'CREATE TABLE widgets' "$PGAPP/db/schema.sql")" "1"
  chk "pg schema dump carries the view" "$(grep -c 'CREATE VIEW widget_totals' "$PGAPP/db/schema.sql")" "1"
  chk "no throwaway schema qualifier leaks" "$(grep -c 'snails_dump_' "$PGAPP/db/schema.sql")" "0"
  # The SET block stays: the schema dump carries the client
  # that made it, and a server that does not know those settings failing
  # to load it is the intended version signal. The scratch search_path
  # clear is the exception — it means nothing after the qualifier go.
  chk "the schema dump keeps pg_dump's session settings" "$(awk '/^SET / { n++ } END { print (n > 0) ? 1 : 0 }' "$PGAPP/db/schema.sql")" "1"
  chk "the scratch search_path clear is stripped" "$(grep -c 'set_config' "$PGAPP/db/schema.sql")" "0"
  chk "no pg_dump banner leaks" "$(awk '/^-- (Name|Dumped|PostgreSQL)/ || /^\\/ { c++ } END { print c+0 }' "$PGAPP/db/schema.sql")" "0"
  before="$(cksum < "$PGAPP/db/schema.sql")"
  out=$(pgmigrate dump 2>&1); code=$?
  chk "pg rerun dump is a no-op" "$code" "0"
  chk_has "pg rerun reports no change" "$out" "up to date"
  chk "pg dump output is deterministic" "$(cksum < "$PGAPP/db/schema.sql")" "$before"

  # verify: byte compare, same repair as sqlite.
  out=$(pgmigrate verify 2>&1); code=$?
  chk "pg verify exits 0" "$code" "0"
  chk_has "pg verify reports the agreement" "$out" "schema dump matches"
  printf '\n-- hand edit\n' >> "$PGAPP/db/schema.sql"
  out=$(pgmigrate verify 2>&1); code=$?
  chk "pg verify catches a hand edit" "$code" "1"
  chk_has "pg verify names the repair" "$out" "run: snails migrate dump"
  pgmigrate dump >/dev/null 2>&1
  out=$(pgmigrate verify 2>&1); code=$?
  chk "pg verify passes after the repair" "$code" "0"

  # The generated schema dump must load into a fresh schema and match the
  # applied migrations — the correctness proof for the pg_dump render.
  psql "$PG_TARGET" -q -c "CREATE SCHEMA IF NOT EXISTS snapcheck;"
  { printf 'SET search_path TO snapcheck;\n'; cat "$PGAPP/db/schema.sql"; } |
    psql "$PG_TARGET" -v ON_ERROR_STOP=1 -q -f -; code=$?
  chk "the generated pg schema dump loads" "$code" "0"
  cols() { psql "$PG_TARGET" -tAc "SELECT table_name||'|'||column_name||'|'||data_type||'|'||is_nullable FROM information_schema.columns WHERE table_schema = '$1' AND table_name <> 'schema_migrations' ORDER BY table_name, column_name"; }
  diff <(cols snapcheck) <(cols public) >/dev/null
  chk "the loaded schema dump matches the applied columns" "$?" "0"
  views() { psql "$PG_TARGET" -tAc "SELECT table_name||'|'||regexp_replace(view_definition, '(snapcheck|public)\.', '', 'g') FROM information_schema.views WHERE table_schema = '$1' ORDER BY table_name"; }
  diff <(views snapcheck) <(views public) >/dev/null
  chk "the loaded schema dump matches the applied views" "$?" "0"

else
  echo "skip: no postgres reachable at $PG_ADMIN (pg cases not counted)"
fi

echo
echo "test-migrate: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
