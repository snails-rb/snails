require_relative "test_helper"
require_relative "harness_runner"
require_relative "test_database"

# ActiveJob::Scheduler (core) — the periodic registry and loop. Cases here cover:
# a registered callback runs once per occurrence — the interval form's window
# start, or the cron form's scheduled time; a fresh registration adopts the
# occurrence that covers its first pass without running it, so a late start
# waits for the next occurrence instead of catching up; the callback runs with
# its own Sqlx::Database lease; and the clock is injectable so timing is
# testable without sleeping. `ActiveJob::Launcher.start` runs the loop.
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

  # The pass unit is private — the loop is the public entry; an outside
  # caller must not drive a pass directly.
  def test_run_once_is_private
    blocked = false
    begin
      ActiveJob::Scheduler.run_once
    rescue NoMethodError
      blocked = true
    end
    assert_equal true, blocked
  end

  # A non-positive interval would divide by zero in the window arithmetic,
  # so registration rejects it immediately instead of killing the loop on
  # the first run.
  def test_register_interval_rejects_non_positive_seconds
    zero = false
    begin
      ActiveJob::Scheduler.register_interval(0, ->(_occurrence) { mark })
    rescue ArgumentError
      zero = true
    end
    assert_equal true, zero

    negative = false
    begin
      ActiveJob::Scheduler.register_interval(-1, ->(_occurrence) { mark })
    rescue ArgumentError
      negative = true
    end
    assert_equal true, negative
    assert_equal 0, ActiveJob::Scheduler::PERIODIC.length
  end

  # Due-ness is an interval window — the same grid the recurring key
  # uses: a fresh registration adopts the CURRENT window on its first
  # pass without running it, then runs exactly once per new window, and
  # windows no run lived through are skipped rather than backfilled.
  def test_window_change_runs_once_per_window
    boundary = Time.utc(2026, 10, 26, 0, 0, 0).to_i
    ActiveJob::Scheduler.register_interval(300, ->(_occurrence) { mark })

    ActiveJob::Scheduler.run_periodic(boundary + 10)
    assert_equal 0, marks

    ActiveJob::Scheduler.run_periodic(boundary + 200)
    assert_equal 0, marks

    ActiveJob::Scheduler.run_periodic(boundary + 300)
    assert_equal 1, marks

    ActiveJob::Scheduler.run_periodic(boundary + 305)
    assert_equal 1, marks

    ActiveJob::Scheduler.run_periodic(boundary + 900)
    assert_equal 2, marks
  end

  # A process that starts mid-window does not run the window it missed: the
  # first pass adopts it, and the callback waits for the next one.
  def test_a_fresh_registration_starts_at_the_next_window
    boundary = Time.utc(2026, 10, 26, 0, 0, 0).to_i
    ActiveJob::Scheduler.register_interval(86_400, ->(_occurrence) { mark })

    ActiveJob::Scheduler.run_periodic(boundary + 40_000)
    assert_equal 0, marks

    ActiveJob::Scheduler.run_periodic(boundary + 41_000)
    assert_equal 0, marks

    ActiveJob::Scheduler.run_periodic(boundary + 86_400)
    assert_equal 1, marks
  end

  # A cron entry runs the occurrence that covers now: the latest scheduled
  # time at or before it. The first pass adopts the covering occurrence without
  # running it, then each next occurrence runs exactly once.
  def test_cron_entry_runs_once_per_occurrence
    cron = Snails::Cron.parse("0 6 * * *")
    ActiveJob::Scheduler.register_cron(cron, ->(_occurrence) { mark })

    # 05:00 adopts the previous day's 06:00; 06:00 is the next occurrence.
    ActiveJob::Scheduler.run_periodic(Time.utc(2026, 11, 18, 5, 0, 0).to_i)
    assert_equal 0, marks

    ActiveJob::Scheduler.run_periodic(Time.utc(2026, 11, 18, 5, 30, 0).to_i)
    assert_equal 0, marks

    ActiveJob::Scheduler.run_periodic(Time.utc(2026, 11, 18, 6, 0, 0).to_i)
    assert_equal 1, marks

    ActiveJob::Scheduler.run_periodic(Time.utc(2026, 11, 18, 6, 1, 0).to_i)
    assert_equal 1, marks

    ActiveJob::Scheduler.run_periodic(Time.utc(2026, 11, 19, 6, 0, 0).to_i)
    assert_equal 2, marks
  end

  # A restart after the scheduled time does not run the occurrence it missed;
  # the first pass adopts it and the next occurrence runs on schedule.
  def test_a_fresh_cron_registration_waits_for_the_next_occurrence
    cron = Snails::Cron.parse("0 6 * * *")
    ActiveJob::Scheduler.register_cron(cron, ->(_occurrence) { mark })

    ActiveJob::Scheduler.run_periodic(Time.utc(2026, 11, 18, 7, 0, 0).to_i)
    assert_equal 0, marks

    ActiveJob::Scheduler.run_periodic(Time.utc(2026, 11, 18, 7, 30, 0).to_i)
    assert_equal 0, marks

    ActiveJob::Scheduler.run_periodic(Time.utc(2026, 11, 19, 6, 0, 0).to_i)
    assert_equal 1, marks
  end

  # One raising callback is reported and does not stop the others (or
  # run_periodic itself) — the rule the job drain already follows. The first
  # pass only adopts the window; the callbacks run on the next one.
  def test_raising_callback_does_not_stop_the_others
    now = Time.now.to_i
    ActiveJob::Scheduler.register_interval(1, ->(_occurrence) { raise "boom" })
    ActiveJob::Scheduler.register_interval(1, ->(_occurrence) { mark })

    ActiveJob::Scheduler.run_periodic(now)
    assert_equal 0, marks

    ActiveJob::Scheduler.run_periodic(now + 1)
    assert_equal 1, marks
    text = @log.messages.join("\n")
    assert_equal true, text.include?("event.name=scheduler.callback_failed")
    assert_equal true, text.include?("exception.type=RuntimeError")
  end

  # A fatal callback stops the loop; scheduler.loop_stopped carries the exception.
  def test_loop_stopped_is_recorded
    ActiveJob::Scheduler.register_interval(1, ->(_occurrence) { raise SystemExit, "stop" })
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

  # A structural failure in the pass is scheduler.run_failed, distinct from a
  # callback failure.
  def test_run_failed_is_recorded
    ActiveJob::Scheduler.register_interval(1, ->(_occurrence) { 0 })
    ActiveJob::Scheduler::PERIODIC[0]["interval"] = nil
    ActiveJob::Scheduler.send(:run_once)
    Snails.logger.flush
    record = @capture.records[0]
    assert_equal "scheduler.run_failed", record.event
    assert_equal :error, record.severity
    assert_equal "TypeError", record.exception_type
  end
end

FixtureRunner.run(JobSchedulerTest, [
  "test_run_once_is_private",
  "test_register_interval_rejects_non_positive_seconds",
  "test_window_change_runs_once_per_window",
  "test_a_fresh_registration_starts_at_the_next_window",
  "test_cron_entry_runs_once_per_occurrence",
  "test_a_fresh_cron_registration_waits_for_the_next_occurrence",
  "test_raising_callback_does_not_stop_the_others",
  "test_loop_stopped_is_recorded",
  "test_run_failed_is_recorded"
])
