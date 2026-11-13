require_relative "test_helper"
require_relative "harness_runner"
require_relative "test_database"

# The queue sink — a module the job bodies append to, so a case can
# tell "the drain reached the body" from "it did not".
module QueueJobSink
  RAN = []
end

# The job body: records the payload value it received (0 for the
# payload-less shape — a nil payload and no payload read the same).
class QueueSinkJob < ActiveJob::Base
  def self.perform(data)
    QueueJobSink::RAN << (data.nil? ? 0 : data["n"])
  end
end

# The failing body: the drain must record it on the row and move on.
class QueueBoomJob < ActiveJob::Base
  def self.perform(data)
    raise "boom"
  end
end

# A job class that never overrides `perform`: the base spec raises
# NotImplementedError (a ScriptError), which the unit boundary must
# record on the row instead of letting it kill the worker loop.
class QueueUnimplementedJob < ActiveJob::Base
end

# ActiveJob::DatabaseQueue (core) — the DB-backed adapter's row
# lifecycle. Pinned here: an enqueue writes one pending row and runs
# nothing; a drain claims a row (one atomic UPDATE), resolves the stored
# name back to a class (`Object.const_get`), runs it with the decoded
# payload, and records the outcome on the same row; failures and
# unresolvable names land on the row instead of vanishing; a claim from
# a dead process is returned to the queue (at-least-once); a recurring
# beat queues once per interval start through the ledger, while a
# one-off schedule keeps every distinct payload. The setup rebuilds the
# queue tables from the shipped DDL template each case — the template
# and the model declarations are one contract, checked below.
class DatabaseQueueAdapterTest < TestBase
  def setup
    TestDatabase.configure!("active_job_database_queue")
    TestDatabase.load_queue_schema!
    ActiveJob::EXECUTORS.clear
    ActiveJob.queue_adapter = ActiveJob::DatabaseQueue
    ActiveJob::DatabaseQueue::LAST_DRAIN_AT[0] = 0
    ActiveJob::DatabaseQueue::LAST_DRAIN_WAS_FULL[0] = false
    QueueJobSink::RAN.clear
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

  def table_columns(table)
    if TestDatabase.pg?
      Sqlx::Base.rows_by_sql("SELECT column_name AS name FROM information_schema.columns " +
                             "WHERE table_schema = current_schema() AND table_name = ? " +
                             "ORDER BY ordinal_position", [ table ]).map { |row| row["name"] }
    else
      Sqlx::Base.rows_by_sql("PRAGMA table_info(" + table + ")").map { |row| row["name"] }
    end
  end

  # The time columns store a time value, not an epoch number: sqlite keeps
  # the runtime's text form, pg its native timestamp.
  def assert_time_column(table)
    if TestDatabase.pg?
      assert_equal "timestamp without time zone",
                   scalar("SELECT data_type FROM information_schema.columns " +
                          "WHERE table_schema = current_schema() AND table_name = '" + table + "' " +
                          "AND column_name = 'scheduled_at'")
    else
      assert_equal "text", scalar("SELECT typeof(scheduled_at) FROM " + table)
    end
  end

  # An enqueue is a row write, not a run: with an executor registered the
  # hand-off returns immediately and the payload travels as JSON text.
  def test_enqueue_writes_one_pending_row_and_runs_nothing
    ActiveJob.register_executor
    ActiveJob.enqueue(QueueSinkJob, { "n" => 7 })
    assert_equal 0, QueueJobSink::RAN.length
    assert_equal "pending", scalar("SELECT status FROM snails_queue_jobs")
    assert_equal "{\"n\":7}", scalar("SELECT payload FROM snails_queue_jobs")
  end

  # A drain claims the row (attempts counted), resolves the stored name
  # to a class, runs it with the decoded payload, and records the
  # outcome — the row IS the execution history.
  def test_drain_claims_runs_and_records_the_row
    ActiveJob.register_executor
    ActiveJob.enqueue(QueueSinkJob, { "n" => 7 })
    ran = ActiveJob::DatabaseQueue.drain
    assert_equal 1, ran
    assert_equal [ 7 ], QueueJobSink::RAN
    assert_equal "succeeded", scalar("SELECT status FROM snails_queue_jobs")
    assert_equal 1, scalar("SELECT attempts FROM snails_queue_jobs")
    assert_equal false, scalar("SELECT finished_at FROM snails_queue_jobs").nil?
  end

  # A raising body is recorded on its row (failed + the message) and
  # the drain runs the next job — one failure never costs the queue the
  # rest.
  def test_a_raising_job_is_recorded_and_the_drain_moves_on
    ActiveJob.register_executor
    ActiveJob.enqueue(QueueBoomJob)
    ActiveJob.enqueue(QueueSinkJob)
    ran = ActiveJob::DatabaseQueue.drain
    assert_equal 2, ran
    assert_equal 1, QueueJobSink::RAN.length
    assert_equal "failed", scalar("SELECT status FROM snails_queue_jobs WHERE name = 'QueueBoomJob'")
    assert_equal "RuntimeError: boom", scalar("SELECT last_error FROM snails_queue_jobs WHERE name = 'QueueBoomJob'")
    assert_equal "succeeded", scalar("SELECT status FROM snails_queue_jobs WHERE name = 'QueueSinkJob'")
  end

  # A name no class carries fails loudly ON THE ROW: the row gets a
  # failed status and the resolver's message, never a silent success.
  def test_an_unknown_name_fails_the_row
    ActiveJob.register_executor
    ActiveJob::DatabaseQueue.enqueue("GhostJob", -> { QueueJobSink::RAN << 0 }, nil)
    ActiveJob::DatabaseQueue.drain
    assert_equal "failed", scalar("SELECT status FROM snails_queue_jobs")
    assert_equal "NameError: uninitialized constant GhostJob", scalar("SELECT last_error FROM snails_queue_jobs")
  end

  # The base `perform` spec raises NotImplementedError (a ScriptError).
  # The unit boundary must record it on the row and the drain must move
  # on to the next due row, never kill the worker loop.
  def test_a_job_without_perform_is_recorded_and_the_drain_moves_on
    ActiveJob.register_executor
    ActiveJob.enqueue(QueueUnimplementedJob)
    ActiveJob.enqueue(QueueSinkJob, { "n" => 11 })

    ran = ActiveJob::DatabaseQueue.drain
    assert_equal 2, ran
    assert_equal [ 11 ], QueueJobSink::RAN
    assert_equal "failed", scalar("SELECT status FROM snails_queue_jobs WHERE name = 'QueueUnimplementedJob'")
    assert_equal "NotImplementedError: perform: subclasses must override", scalar("SELECT last_error FROM snails_queue_jobs WHERE name = 'QueueUnimplementedJob'")
    assert_equal "succeeded", scalar("SELECT status FROM snails_queue_jobs WHERE name = 'QueueSinkJob'")
  end

  # A claim older than the orphan window means its process is dead —
  # the next drain returns the row to pending and runs it again (the
  # attempts counter already holds the lost run).
  def test_a_stale_running_row_is_reclaimed
    ActiveJob.register_executor
    stale = Time.now.utc - 3600
    Sqlx::Base.write("INSERT INTO snails_queue_jobs (name, payload, status, scheduled_at, started_at, attempts, created_at, updated_at) " +
                     "VALUES (?, ?, 'running', ?, ?, 1, ?, ?)",
                     [ "QueueSinkJob", "{\"n\":5}", stale, stale, stale, stale ])
    ran = ActiveJob::DatabaseQueue.drain
    assert_equal 1, ran
    assert_equal 5, QueueJobSink::RAN[0]
    assert_equal "succeeded", scalar("SELECT status FROM snails_queue_jobs")
    assert_equal 2, scalar("SELECT attempts FROM snails_queue_jobs")
  end

  # Without a registered executor the hand-off runs at the call site — a
  # queue nobody drains would be a silent loss, so there is no row and
  # no wait.
  def test_without_an_executor_the_call_site_runs_the_job
    ActiveJob.enqueue(QueueSinkJob, { "n" => 9 })
    assert_equal 1, QueueJobSink::RAN.length
    assert_equal nil, scalar("SELECT status FROM snails_queue_jobs")
  end

  # The recurring hand-off is idempotent per interval start: the
  # ledger's (job name, interval start) key drops the second call, so
  # several processes firing the same beat still queue one row — the
  # first caller answers true, the duplicate false.
  def test_enqueue_once_is_idempotent_per_interval_start
    slot = Time.now.utc
    first = ActiveJob::DatabaseQueue.enqueue_once("QueueSinkJob", -> { QueueJobSink::RAN << 0 }, nil, slot)
    second = ActiveJob::DatabaseQueue.enqueue_once("QueueSinkJob", -> { QueueJobSink::RAN << 0 }, nil, slot)
    assert_equal true, first
    assert_equal false, second
    assert_equal 1, scalar("SELECT COUNT(*) FROM snails_queue_jobs")
    assert_equal "pending", scalar("SELECT status FROM snails_queue_jobs")
  end

  # The occurrence lands on the ledger in the same transaction as the
  # queue row — one ledger row per beat, stored as a time value.
  def test_enqueue_once_records_the_occurrence
    slot = Time.now.utc
    ActiveJob::DatabaseQueue.enqueue_once("QueueSinkJob", -> { QueueJobSink::RAN << 0 }, nil, slot)
    table = Snails::Queue::Occurrence.table_name
    assert_equal 1, scalar("SELECT COUNT(*) FROM " + table)
    assert_equal "QueueSinkJob", scalar("SELECT job_name FROM " + table)
    assert_time_column(table)
  end

  # The interval start the beat computed travels as a Time and lands
  # as a time value — an integer epoch would store as a number and the
  # time columns would no longer read as times.
  def test_enqueue_once_stores_the_interval_start_as_a_time
    start = ActiveJob.scheduled_at_for(300, Time.utc(2026, 10, 16, 18, 37, 12))
    ActiveJob::DatabaseQueue.enqueue_once("QueueSinkJob", -> { QueueJobSink::RAN << 0 }, nil, start)
    assert_time_column("snails_queue_jobs")
    assert_equal 1, scalar("SELECT COUNT(*) FROM snails_queue_jobs" +
                           " WHERE scheduled_at = '2026-10-16 18:35:00.000000'")
  end

  # A value outside the contract (not a Time) never reaches a row: the
  # typed slot refuses it at the boundary (the untyped JSON number
  # gets a TypeError from the call, and a literal would not compile).
  def test_enqueue_once_rejects_a_value_that_is_not_a_time
    rejected = false
    value = JSON.parse("1792175700")
    begin
      ActiveJob.queue_adapter.enqueue_once("QueueSinkJob", -> { QueueJobSink::RAN << 0 }, nil, value)
    rescue TypeError
      rejected = true
    end
    assert_equal true, rejected
    assert_equal 0, scalar("SELECT COUNT(*) FROM snails_queue_jobs")
  end

  # A delayed one-off carries its run time into the row's scheduled_at
  # and stays pending until a drain's clock passes it.
  def test_enqueue_at_stores_the_run_time_as_a_time
    ActiveJob.register_executor
    at = Time.utc(2026, 10, 18, 12, 0, 0)
    ActiveJob.schedule(QueueSinkJob, at)
    assert_time_column("snails_queue_jobs")
    assert_equal 1, scalar("SELECT COUNT(*) FROM snails_queue_jobs" +
                           " WHERE scheduled_at = '2026-10-18 12:00:00.000000'")
  end

  # One-off schedules are NOT deduplicated: the same name and run time
  # with different payloads are different jobs, so both rows stand (a
  # single (name, time) key would silently drop the second one).
  def test_enqueue_at_keeps_distinct_payloads_at_the_same_time
    ActiveJob.register_executor
    at = Time.utc(2026, 10, 23, 12, 0, 0)
    ActiveJob.schedule(QueueSinkJob, at, { "n" => 1 })
    ActiveJob.schedule(QueueSinkJob, at, { "n" => 2 })
    assert_equal 2, scalar("SELECT COUNT(*) FROM snails_queue_jobs")
    assert_equal 2, scalar("SELECT COUNT(DISTINCT payload) FROM snails_queue_jobs")
  end

  # A recurring occurrence and a one-off schedule at the same instant
  # are different keys: the ledger and the queue row never collide, so
  # both stand.
  def test_a_recurring_occurrence_and_a_one_off_schedule_coexist
    slot = Time.now.utc
    ActiveJob::DatabaseQueue.enqueue_once("QueueSinkJob", -> { QueueJobSink::RAN << 0 }, nil, slot)
    ActiveJob.register_executor
    ActiveJob.schedule(QueueSinkJob, slot, { "n" => 9 })
    assert_equal 2, scalar("SELECT COUNT(*) FROM snails_queue_jobs")
  end

  # A row scheduled for later is not due: the drain passes it by and
  # it stays pending.
  def test_a_future_row_waits_for_its_time
    ActiveJob.register_executor
    ActiveJob.schedule(QueueSinkJob, Time.now.utc + 3600)
    ran = ActiveJob::DatabaseQueue.drain
    assert_equal 0, ran
    assert_equal "pending", scalar("SELECT status FROM snails_queue_jobs")
    assert_equal 0, QueueJobSink::RAN.length
  end

  # Once due, a scheduled row runs on the same path as a plain
  # hand-off, payload included.
  def test_a_due_scheduled_row_runs_on_the_drain
    ActiveJob.register_executor
    ActiveJob.schedule(QueueSinkJob, Time.now.utc - 1, { "n" => 3 })
    ran = ActiveJob::DatabaseQueue.drain
    assert_equal 1, ran
    assert_equal 3, QueueJobSink::RAN[0]
    assert_equal "succeeded", scalar("SELECT status FROM snails_queue_jobs")
  end

  # The claim picks due rows only — a future row sitting first in the
  # table never blocks a due one behind it.
  def test_a_future_row_does_not_block_due_rows
    ActiveJob.register_executor
    ActiveJob.enqueue(QueueSinkJob, { "n" => 1 })
    ActiveJob.schedule(QueueSinkJob, Time.now.utc + 3600, { "n" => 2 })
    ran = ActiveJob::DatabaseQueue.drain
    assert_equal 1, ran
    assert_equal 1, QueueJobSink::RAN[0]
    assert_equal 1, scalar("SELECT COUNT(*) FROM snails_queue_jobs WHERE status = 'pending'")
    assert_equal 1, scalar("SELECT COUNT(*) FROM snails_queue_jobs WHERE status = 'succeeded'")
  end

  # Every schedule call writes a row — one-off queues carry no
  # deduplication at all (the ledger is recurring traffic only).
  def test_one_off_schedules_are_not_deduplicated
    ActiveJob.register_executor
    at = Time.now.utc + 3600
    ActiveJob.schedule(QueueSinkJob, at)
    ActiveJob.schedule(QueueSinkJob, at)
    assert_equal 2, scalar("SELECT COUNT(*) FROM snails_queue_jobs")
  end

  # A full batch means more due rows may be waiting: the next drain is
  # due at once (the worker's 50ms poll drives it, not the interval).
  # A shorter drain clears that and the idle interval takes over. The
  # drain clock is pushed into the future before each assertion so only
  # the full-drain signal can answer — a second boundary crossed during
  # the drain must not make the interval-only behavior look correct.
  def test_a_full_batch_keeps_the_next_drain_due
    ActiveJob.register_executor
    (ActiveJob::DatabaseQueue::BATCH_SIZE + 2).times { |i| ActiveJob.enqueue(QueueSinkJob, { "n" => i }) }

    ran = ActiveJob::DatabaseQueue.drain
    assert_equal ActiveJob::DatabaseQueue::BATCH_SIZE, ran
    ActiveJob::DatabaseQueue::LAST_DRAIN_AT[0] = Time.now.to_i + 3600
    assert_equal true, ActiveJob::DatabaseQueue.drain_due?

    ran = ActiveJob::DatabaseQueue.drain
    assert_equal 2, ran
    ActiveJob::DatabaseQueue::LAST_DRAIN_AT[0] = Time.now.to_i + 3600
    assert_equal false, ActiveJob::DatabaseQueue.drain_due?
    assert_equal 12, QueueJobSink::RAN.length
  end

  # Concurrent worker threads (WORKER_CONCURRENCY > 1) never claim the same
  # row twice: the claim is a single atomic UPDATE, so the batch is split
  # between the worker threads and every row runs exactly once.
  def test_concurrent_worker_threads_share_the_queue_without_double_claiming
    ActiveJob.register_executor
    20.times { |i| ActiveJob.enqueue(QueueSinkJob, { "n" => i }) }

    total = [ 0 ]
    lock = Mutex.new
    threads = []
    3.times do
      threads << Thread.new do
        while true
          delta = Sqlx::Database.with_connection { ActiveJob::DatabaseQueue.drain }
          lock.synchronize { total[0] = total[0] + delta }
          break if delta == 0
        end
      end
    end
    threads.each { |t| t.join }

    assert_equal 20, total[0]
    assert_equal 20, QueueJobSink::RAN.length
    assert_equal 20, scalar("SELECT COUNT(*) FROM snails_queue_jobs WHERE status = 'succeeded'")
    assert_equal 0, scalar("SELECT COUNT(*) FROM snails_queue_jobs WHERE status = 'running'")
  end

  # The shipped DDL template and the hand-written model declarations
  # are two halves of one contract: the template is what generate
  # stamps into an app, the declarations are what hydrates its rows —
  # a column drifting out of either shows up here.
  def test_the_template_and_the_model_declare_the_same_columns
    assert_equal Snails::Queue::Job.only_columns.map { |c| c.to_s }.sort, table_columns("snails_queue_jobs").sort
    assert_equal Snails::Queue::Occurrence.only_columns.map { |c| c.to_s }.sort, table_columns("snails_queue_occurrences").sort
    declared = Snails::Queue::Job.only_columns.map { |c| c.to_s }
    (Snails::Queue::Job.datetime_columns + Snails::Queue::Job.json_columns).each do |name|
      assert_equal true, declared.include?(name)
    end
    occurrences_declared = Snails::Queue::Occurrence.only_columns.map { |c| c.to_s }
    Snails::Queue::Occurrence.datetime_columns.each do |name|
      assert_equal true, occurrences_declared.include?(name)
    end
  end

  # A full row hydrates through those declarations: the time columns
  # come back as Time, the payload as its logical JSON value — the
  # codec never surfaces as storage text.
  def test_a_full_row_hydrates_through_the_declarations
    ActiveJob.register_executor
    ActiveJob.enqueue(QueueSinkJob, { "n" => 4 })
    row = Snails::Queue::Job.find_by_sql("SELECT * FROM snails_queue_jobs")[0]
    assert_equal true, row.scheduled_at.is_a?(Time)
    assert_equal({ "n" => 4 }, row.payload)
    assert_equal "pending", row.status
    assert_equal 0, row.attempts
  end

  # Row-by-row execution is not a caller's surface — the drain is the
  # entry, and the helper stays behind the class (boundary: an outside
  # call is a NoMethodError, not a usable back door).
  def test_perform_claimed_is_private
    blocked = false
    begin
      ActiveJob::DatabaseQueue.perform_claimed(nil)
    rescue NoMethodError
      blocked = true
    end
    assert_equal true, blocked
  end
end

FixtureRunner.run(DatabaseQueueAdapterTest, [
  "test_enqueue_writes_one_pending_row_and_runs_nothing",
  "test_drain_claims_runs_and_records_the_row",
  "test_a_raising_job_is_recorded_and_the_drain_moves_on",
  "test_an_unknown_name_fails_the_row",
  "test_a_job_without_perform_is_recorded_and_the_drain_moves_on",
  "test_a_stale_running_row_is_reclaimed",
  "test_without_an_executor_the_call_site_runs_the_job",
  "test_enqueue_once_is_idempotent_per_interval_start",
  "test_enqueue_once_records_the_occurrence",
  "test_enqueue_once_stores_the_interval_start_as_a_time",
  "test_enqueue_once_rejects_a_value_that_is_not_a_time",
  "test_enqueue_at_stores_the_run_time_as_a_time",
  "test_enqueue_at_keeps_distinct_payloads_at_the_same_time",
  "test_a_recurring_occurrence_and_a_one_off_schedule_coexist",
  "test_a_future_row_waits_for_its_time",
  "test_a_due_scheduled_row_runs_on_the_drain",
  "test_a_future_row_does_not_block_due_rows",
  "test_one_off_schedules_are_not_deduplicated",
  "test_a_full_batch_keeps_the_next_drain_due",
  "test_concurrent_worker_threads_share_the_queue_without_double_claiming",
  "test_the_template_and_the_model_declare_the_same_columns",
  "test_a_full_row_hydrates_through_the_declarations",
  "test_perform_claimed_is_private"
])
