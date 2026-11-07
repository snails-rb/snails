require_relative "test_helper"
require_relative "harness_runner"
require_relative "test_database"

# Snails::QueuePruneJob (core) — the queue retention pass. Pinned here:
# only finished rows (succeeded/failed) past the retention window are
# deleted — recent rows and pending rows stand regardless of
# age — the ledger's old occurrences go with them (one window for both
# tables), each delete stops at the batch limit, and a backlog larger
# than one batch is cleared by repetition. The setup rebuilds the queue
# tables from the shipped DDL template each case; rows are inserted
# directly, because this case is about the retention rule, not the
# drain path.
class QueuePruneJobTest < TestBase
  PRUNE_INDEX = "index_snails_queue_jobs_on_status_and_finished_at"

  def setup
    TestDatabase.configure!("snails_queue_prune")
    TestDatabase.load_queue_schema!
  end

  def assert_equal(expected, actual, msg = nil)
    raise(msg || "expected #{expected.inspect}, got #{actual.inspect}") unless expected == actual
  end

  # First row, first column — one value out, in the adapter's own types.
  def scalar(sql)
    row = Sqlx::Base.row_by_sql(sql)
    return nil if row.nil?

    row[row.keys[0]]
  end

  def insert_row(name, status, finished_at, scheduled_at)
    Sqlx::Base.write("INSERT INTO snails_queue_jobs (name, payload, status, scheduled_at, finished_at, attempts, created_at, updated_at) " +
                     "VALUES (?, NULL, ?, ?, ?, 0, ?, ?)",
                     [ name, status, scheduled_at, finished_at, scheduled_at, scheduled_at ])
  end

  def insert_occurrence(job_name, scheduled_at)
    Sqlx::Base.write("INSERT INTO snails_queue_occurrences (job_name, scheduled_at, created_at) VALUES (?, ?, ?)",
                     [ job_name, scheduled_at, scheduled_at ])
  end

  def index_names(table)
    if TestDatabase.pg?
      Sqlx::Base.rows_by_sql("SELECT indexname AS name FROM pg_indexes " +
                             "WHERE schemaname = current_schema() AND tablename = ?", [ table ]).map { |row| row["name"] }
    else
      Sqlx::Base.rows_by_sql("SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = ?",
                             [ table ]).map { |row| row["name"] }
    end
  end

  # The deletion rule is one condition — finished AND past the window:
  # an old succeeded row goes, a recent failed row and a pending row
  # stay.
  def test_prune_removes_only_finished_rows_past_retention
    now = Time.now.utc
    old = 8.days.ago
    insert_row("OldSucceededJob", "succeeded", old, old)
    insert_row("RecentFailedJob", "failed", now, now)
    insert_row("PendingJob", "pending", nil, old)

    Snails::QueuePruneJob.perform(nil)

    assert_equal 2, scalar("SELECT COUNT(*) FROM snails_queue_jobs")
    assert_equal 1, scalar("SELECT COUNT(*) FROM snails_queue_jobs WHERE status = 'failed'")
    assert_equal 1, scalar("SELECT COUNT(*) FROM snails_queue_jobs WHERE status = 'pending'")
  end

  # The ledger shares the window: an old occurrence goes, a recent one
  # stays — a queue and its ledger never disagree about what is old.
  def test_prune_removes_old_occurrences
    now = Time.now.utc
    old = 8.days.ago
    insert_occurrence("OldOccurrence", old)
    insert_occurrence("RecentOccurrence", now)

    Snails::QueuePruneJob.perform(nil)

    assert_equal 1, scalar("SELECT COUNT(*) FROM snails_queue_occurrences")
    assert_equal "RecentOccurrence", scalar("SELECT job_name FROM snails_queue_occurrences")
  end

  # The shipped template carries the index the retention sweep reads —
  # a template without it would still pass the row cases above while
  # walking every finished row on a real backlog.
  def test_the_template_ships_the_retention_index
    assert_equal true, index_names("snails_queue_jobs").include?(PRUNE_INDEX)
  end

  # One delete stops at the limit: with more old rows than one batch,
  # exactly one batch goes and the rest waits for the next call.
  def test_one_prune_call_stops_at_the_batch_limit
    old = 8.days.ago
    (Snails::QueuePruneJob::PRUNE_BATCH_SIZE + 2).times do |i|
      insert_row("OldBatchJob" + i.to_s, "succeeded", old, old)
    end

    deleted = Snails::QueueJob.prune_finished!(Time.now.utc, limit: Snails::QueuePruneJob::PRUNE_BATCH_SIZE)

    assert_equal Snails::QueuePruneJob::PRUNE_BATCH_SIZE, deleted
    assert_equal 2, scalar("SELECT COUNT(*) FROM snails_queue_jobs")
  end

  # A backlog larger than one batch is cleared by repetition: the job
  # keeps deleting until a short batch comes back, and both tables end
  # empty of rows past the window while recent rows stay.
  def test_the_job_clears_a_backlog_larger_than_one_batch
    now = Time.now.utc
    old = 8.days.ago
    over_one_batch = Snails::QueuePruneJob::PRUNE_BATCH_SIZE + 5
    over_one_batch.times do |i|
      insert_row("OldBacklogJob" + i.to_s, "failed", old, old)
      insert_occurrence("OldBacklogOccurrence" + i.to_s, old)
    end
    insert_row("RecentJob", "succeeded", now, now)
    insert_occurrence("RecentOccurrence", now)

    Snails::QueuePruneJob.perform(nil)

    assert_equal 0, scalar("SELECT COUNT(*) FROM snails_queue_jobs WHERE status = 'failed'")
    assert_equal 1, scalar("SELECT COUNT(*) FROM snails_queue_jobs")
    assert_equal 1, scalar("SELECT COUNT(*) FROM snails_queue_occurrences")
  end

  # A zero or negative limit would delete nothing (or mean "no bound")
  # and a looping caller would never finish — both entries reject it
  # instead of quietly returning 0.
  def test_prune_rejects_a_non_positive_limit
    raised = 0
    begin
      Snails::QueueJob.prune_finished!(Time.now.utc, limit: 0)
    rescue ArgumentError
      raised += 1
    end
    begin
      Snails::QueueOccurrence.prune_before!(Time.now.utc, limit: -1)
    rescue ArgumentError
      raised += 1
    end
    assert_equal 2, raised
  end
end

FixtureRunner.run(QueuePruneJobTest, [
  "test_prune_removes_only_finished_rows_past_retention",
  "test_prune_removes_old_occurrences",
  "test_the_template_ships_the_retention_index",
  "test_one_prune_call_stops_at_the_batch_limit",
  "test_the_job_clears_a_backlog_larger_than_one_batch",
  "test_prune_rejects_a_non_positive_limit"
])
