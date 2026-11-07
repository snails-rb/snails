# shellcheck shell=bash
# shellcheck disable=SC2034  # PG_ADMIN/PG_DB/PG_TARGET are read by the sourcing script

# Shared scratch PostgreSQL database for the repo-only verification scripts.
# Source this file; do not execute it.
#
# The callers create one database per run and drop it on exit. PG_URL names
# the server connection; the local default is used when it is unset.
# pg_scratch_create sets PG_DB and PG_TARGET for the caller.
#
# Usage:
#   source scripts/pg-scratch.sh
#   if pg_scratch_available; then
#     pg_scratch_create "snails_<script>"
#     trap 'pg_scratch_drop' EXIT
#   fi

PG_ADMIN="${PG_URL:-postgres://postgres:postgres@127.0.0.1:5432/postgres}"
PG_DB=""
PG_TARGET=""

# True when psql can reach the server.
pg_scratch_available() {
  command -v psql >/dev/null 2>&1 && psql "$PG_ADMIN" -tAc "SELECT 1" >/dev/null 2>&1
}

# Create <prefix>_<pid> on the server. Sets PG_DB and PG_TARGET; returns
# psql's status so the caller can print its own purpose-first failure.
pg_scratch_create() {
  local prefix="$1"
  PG_DB="${prefix}_$$"
  PG_TARGET="$(printf '%s' "$PG_ADMIN" | sed "s#/[^/]*\$#/$PG_DB#")"
  psql "$PG_ADMIN" -q -c "CREATE DATABASE $PG_DB" >/dev/null 2>&1
}

# Drop the scratch database if one was created. Idempotent: the exit trap may
# run after a failed create or a second cleanup.
pg_scratch_drop() {
  if [[ -n $PG_DB ]]; then
    psql "$PG_ADMIN" -q -c "DROP DATABASE IF EXISTS $PG_DB" >/dev/null 2>&1 || true
    PG_DB=""
    PG_TARGET=""
  fi
}
