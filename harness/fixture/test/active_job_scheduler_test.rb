require_relative "test_helper"
require_relative "harness_runner"
require_relative "test_database"

# ActiveJob::Scheduler (core) — the periodic registry and loop. Pinned here:
# a registered callback fires once per calendar bucket on the shared grid; a
# fresh registration catches up the bucket it was registered in, so a restart
# more frequent than the interval never starves it; the callback runs with its
# own Sqlx::Database lease; and the clock is injectable so timing is testable
# without sleeping. `ActiveJob::Launcher.start` runs the loop.
class JobSchedulerTest < TestBase
  def setup
    TestDatabase.configure!("active_job_scheduler")
    TestDatabase.drop_tables!("periodic_marks")
    TestDatabase.exec("CREATE TABLE periodic_marks (n INTEGER)")
    ActiveJob::Scheduler::PERIODIC.clear
    Snails.logger.transport = nil
    Snails.logger.flush
    @log = CapturedLog.new
    Snails.logger.output = @log
    Snails.logger.formatter = MessageOnlyFormatter.new
    @capture = RecordCapture.new
    Snails.logger.transport = @capture
    Snails.logger.level = :info
  end

  def assert_equal(expected, actual, msg = nil)
    raise(msg || "expected #{expected.inspect}, got #{actual.inspect}") unless expected == actual
  end

  # The callback body — it touches the DB, so a missing loop-side lease
  # fails here rather than silently borrowing a request's handle.
  def mark
    Sqlx::Database.exec("INSERT INTO periodic_marks (n) VALUES (1)")
  end

  def marks
    rows = Sqlx::Base.rows_by_sql("SELECT COUNT(*) AS total FROM periodic_marks")
    rows[0]["total"].to_i
  end

  # The run unit is private — the loop is the public entry; an outside
  # caller must not drive a run directly.
  def test_fire_due_callbacks_is_private
    blocked = false
    begin
      ActiveJob::Scheduler.fire_due_callbacks
    rescue NoMethodError
      blocked = true
    end
    assert_equal true, blocked
  end

  # A non-positive interval would divide by zero in the bucket arithmetic,
  # so registration rejects it immediately instead of killing the loop on
  # the first run.
  def test_register_periodic_rejects_non_positive_seconds
    zero = false
    begin
      ActiveJob::Scheduler.register_periodic(0, -> { mark })
    rescue ArgumentError
      zero = true
    end
    assert_equal true, zero

    negative = false
    begin
      ActiveJob::Scheduler.register_periodic(-1, -> { mark })
    rescue ArgumentError
      negative = true
    end
    assert_equal true, negative
    assert_equal 0, ActiveJob::Scheduler::PERIODIC.length
  end

  # Due-ness is a calendar bucket — the same grid the recurring key
  # stamps: a fresh registration fires the CURRENT bucket on its first
  # run, then exactly once per new bucket, and buckets no run lived
  # through are skipped rather than backfilled (one fire covers the
  # jump).
  def test_bucket_change_gates_and_fires_once_per_bucket
    boundary = Time.utc(2026, 10, 26, 0, 0, 0).to_i
    ActiveJob::Scheduler.register_periodic(300, -> { mark })

    ActiveJob::Scheduler.run_periodic(boundary + 10)
    assert_equal 1, marks

    ActiveJob::Scheduler.run_periodic(boundary + 200)
    assert_equal 1, marks

    ActiveJob::Scheduler.run_periodic(boundary + 300)
    assert_equal 2, marks

    ActiveJob::Scheduler.run_periodic(boundary + 305)
    assert_equal 2, marks

    ActiveJob::Scheduler.run_periodic(boundary + 900)
    assert_equal 3, marks
  end

  # A restart inside a bucket cannot starve the beat: the fresh
  # registration carries no bucket, so its first run claims the current
  # one — a process alive at any moment of a long interval covers that
  # interval's bucket (the store adapter's unique key drops the repeats
  # across processes and restarts).
  def test_a_fresh_registration_catches_up_the_current_bucket
    boundary = Time.utc(2026, 10, 26, 0, 0, 0).to_i
    ActiveJob::Scheduler.register_periodic(86_400, -> { mark })

    ActiveJob::Scheduler.run_periodic(boundary + 40_000)
    assert_equal 1, marks

    ActiveJob::Scheduler.run_periodic(boundary + 41_000)
    assert_equal 1, marks

    ActiveJob::Scheduler.run_periodic(boundary + 86_400)
    assert_equal 2, marks
  end

  # One raising callback is reported and does not stop the others (or
  # run_periodic itself) — the rule the job drain already follows.
  def test_raising_callback_does_not_stop_the_others
    now = Time.now.to_i
    ActiveJob::Scheduler.register_periodic(1, -> { raise "boom" })
    ActiveJob::Scheduler.register_periodic(1, -> { mark })

    ActiveJob::Scheduler.run_periodic(now + 1)
    assert_equal 1, marks
    text = @log.messages.join("\n")
    assert_equal true, text.include?("event.name=scheduler.callback_failed")
    assert_equal true, text.include?("exception.type=RuntimeError")
  end

  # A fatal callback stops the loop; scheduler.loop_stopped carries the exception.
  def test_loop_stopped_is_recorded
    ActiveJob::Scheduler.register_periodic(1, -> { raise SystemExit, "stop" })
    begin
      ActiveJob::Scheduler.run
    rescue SystemExit
    end
    Snails.logger.flush
    record = @capture.records[0]
    assert_equal "scheduler.loop_stopped", record.event
    assert_equal :error, record.severity
    assert_equal "SystemExit", record.exception_type
  end

  # A structural failure in the run is scheduler.run_failed, distinct from a
  # callback failure.
  def test_run_failed_is_recorded
    ActiveJob::Scheduler.register_periodic(1, -> { 0 })
    ActiveJob::Scheduler::PERIODIC[0]["interval"] = nil
    ActiveJob::Scheduler.send(:fire_due_callbacks)
    Snails.logger.flush
    record = @capture.records[0]
    assert_equal "scheduler.run_failed", record.event
    assert_equal :error, record.severity
    assert_equal "TypeError", record.exception_type
  end
end

FixtureRunner.run(JobSchedulerTest, [
  "test_fire_due_callbacks_is_private",
  "test_register_periodic_rejects_non_positive_seconds",
  "test_bucket_change_gates_and_fires_once_per_bucket",
  "test_a_fresh_registration_catches_up_the_current_bucket",
  "test_raising_callback_does_not_stop_the_others",
  "test_loop_stopped_is_recorded",
  "test_run_failed_is_recorded"
])
