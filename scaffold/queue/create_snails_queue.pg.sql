-- The DB-backed queue (`ActiveJob::DatabaseQueue`), postgresql variant.
-- Same shape as the sqlite template: one row per job in
-- snails_queue_jobs (a finished row is that run's history) plus the
-- recurring-occurrence ledger snails_queue_occurrences keyed by
-- (job name, interval start). Time columns are native TIMESTAMP — the
-- adapter binds its stored time text and PostgreSQL interprets it —
-- and BIGSERIAL keeps row ids increasing for the life of the table,
-- which the claim order ("oldest due row first") reads.
--
-- `snails generate job_queue` stamps this file into db/migrate/ (with a
-- UTC timestamp version prefix and the `.pg` adapter suffix) and
-- regenerates the db/schema.sql snapshot from the migration files.
-- Every statement is idempotent, so reapplying it over an existing
-- database is safe.
CREATE TABLE IF NOT EXISTS snails_queue_jobs (
  id BIGSERIAL PRIMARY KEY,
  name TEXT NOT NULL,
  payload TEXT,
  status TEXT NOT NULL,
  scheduled_at TIMESTAMP NOT NULL,
  started_at TIMESTAMP,
  finished_at TIMESTAMP,
  attempts INTEGER NOT NULL DEFAULT 0,
  last_error TEXT,
  created_at TIMESTAMP NOT NULL,
  updated_at TIMESTAMP NOT NULL
);
CREATE INDEX IF NOT EXISTS index_snails_queue_jobs_on_status_and_id ON snails_queue_jobs (status, id);
-- The retention sweep finds finished rows by (status, finished_at); without
-- this index it walks every finished row to reach the rows past the window.
CREATE INDEX IF NOT EXISTS index_snails_queue_jobs_on_status_and_finished_at ON snails_queue_jobs (status, finished_at);

CREATE TABLE IF NOT EXISTS snails_queue_occurrences (
  job_name TEXT NOT NULL,
  scheduled_at TIMESTAMP NOT NULL,
  created_at TIMESTAMP NOT NULL,
  PRIMARY KEY (job_name, scheduled_at)
);
CREATE INDEX IF NOT EXISTS index_snails_queue_occurrences_on_scheduled_at ON snails_queue_occurrences (scheduled_at);
