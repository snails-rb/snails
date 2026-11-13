-- The DB-backed queue (`ActiveJob::DatabaseQueue`), sqlite variant.
-- One row per job in snails_queue_jobs — a finished row (succeeded or
-- failed) is that run's history — plus the recurring-occurrence ledger
-- snails_queue_occurrences, one row per (job name, interval start), which
-- ensures a recurring beat is enqueued once across processes.
-- A one-off delayed job writes only the queue row: the ledger is
-- recurring traffic alone.
--
-- `snails generate job_queue` stamps this file into db/migrate/ (with a
-- UTC timestamp version prefix) and regenerates db/schema.sql from the
-- migration files. Every statement is idempotent, so
-- reapplying it over an existing database is safe. AUTOINCREMENT keeps
-- row ids increasing for the life of the table (a pruned id is never
-- reused), which the claim order ("oldest due row first") relies on.
CREATE TABLE IF NOT EXISTS snails_queue_jobs (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL,
  payload TEXT,
  status TEXT NOT NULL,
  scheduled_at datetime NOT NULL,
  started_at datetime,
  finished_at datetime,
  attempts INTEGER NOT NULL DEFAULT 0,
  last_error TEXT,
  created_at datetime NOT NULL,
  updated_at datetime NOT NULL
);
CREATE INDEX IF NOT EXISTS index_snails_queue_jobs_on_status_and_id ON snails_queue_jobs (status, id);
-- The retention sweep finds finished rows by (status, finished_at); without
-- this index it walks every finished row to reach the rows past the window.
CREATE INDEX IF NOT EXISTS index_snails_queue_jobs_on_status_and_finished_at ON snails_queue_jobs (status, finished_at);

CREATE TABLE IF NOT EXISTS snails_queue_occurrences (
  job_name TEXT NOT NULL,
  scheduled_at datetime NOT NULL,
  created_at datetime NOT NULL,
  PRIMARY KEY (job_name, scheduled_at)
);
CREATE INDEX IF NOT EXISTS index_snails_queue_occurrences_on_scheduled_at ON snails_queue_occurrences (scheduled_at);
