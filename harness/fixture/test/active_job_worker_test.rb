require_relative "test_helper"
require_relative "harness_runner"
require_relative "test_database"

# The job bodies the hand-off cases drive — WorkerMarkJob records a run
# in the marks table, WorkerBoomJob raises (the drain's failure pair).
class WorkerMarkJob < ActiveJob::Base
  def self.perform(data)
    Sqlx::Database.exec("INSERT INTO periodic_marks (n) VALUES (1)")
  end
end

class WorkerBoomJob < ActiveJob::Base
  def self.perform(data)
    raise "boom"
  end
end

# The base `perform` spec raises NotImplementedError — a ScriptError, not
# a StandardError — and the drain must still report and move on.
class WorkerUnimplementedJob < ActiveJob::Base
end

# A queue adapter that fails its first drain and stops the loop on the
# second: the failure must be reported, and the second call proves the
# loop reached another drain instead of dying with the first.
class FailingThenExitingAdapter
  CALLS = []

  def self.drain_due?
    true
  end

  def self.drain
    CALLS << 1
    if CALLS.length == 1
      raise NotImplementedError, "adapter drain"
    end
    raise SystemExit, "stop"
  end
end

# ActiveJob::Worker (core) — the drain loop. Pinned here: the drain round
# trip (a queued job runs on drain, and a raising job is reported without
# stopping the drain) and the loop's failure boundary. The loop itself is a
# `while true` that `ActiveJob::Launcher.start` spawns once per worker
# thread, so it is compiled here but not run except by the failure case.
class JobWorkerTest < TestBase
  def setup
    TestDatabase.configure!("active_job_worker")
    TestDatabase.drop_tables!("periodic_marks")
    TestDatabase.exec("CREATE TABLE periodic_marks (n INTEGER)")
    ActiveJob.queue_adapter = ActiveJob::ProcessQueue
    ActiveJob::ProcessQueue::PENDING.clear
    FailingThenExitingAdapter::CALLS.clear
    @log = CapturedLog.new
    Snails.logger.output = @log
    Snails.logger.formatter = MessageOnlyFormatter.new
  end

  def assert_equal(expected, actual, msg = nil)
    raise(msg || "expected #{expected.inspect}, got #{actual.inspect}") unless expected == actual
  end

  # The job body — it touches the DB, so a missing loop-side lease fails
  # here rather than silently borrowing a request's handle.
  def mark
    Sqlx::Database.exec("INSERT INTO periodic_marks (n) VALUES (1)")
  end

  def marks
    rows = Sqlx::Base.rows_by_sql("SELECT COUNT(*) AS total FROM periodic_marks")
    rows[0]["total"].to_i
  end

  # No executor registered: enqueue runs the job at the call site — a job
  # put on a queue nobody drains would be silently lost.
  def test_no_executor_runs_at_the_call_site
    ActiveJob::EXECUTORS.clear
    ActiveJob.enqueue(WorkerMarkJob)
    assert_equal 1, marks
  end

  # The drain round trip: queued jobs run FIFO on drain, and a raising
  # job — including the base `perform` spec's NotImplementedError — is
  # reported without stopping the drain or losing its neighbors.
  def test_drain_round_trip_isolates_failures
    ActiveJob.register_executor
    ActiveJob.enqueue(WorkerMarkJob)
    ActiveJob.enqueue(WorkerBoomJob)
    ActiveJob.enqueue(WorkerUnimplementedJob)
    ActiveJob.enqueue(WorkerMarkJob)
    assert_equal 4, ActiveJob::ProcessQueue.pending_count
    assert_equal 0, marks

    ran = ActiveJob::ProcessQueue.drain
    assert_equal 2, ran
    assert_equal 2, marks
    assert_equal 0, ActiveJob::ProcessQueue.pending_count
    text = @log.messages.join("\n")
    assert_equal true, text.include?("event.name=job.finished")
    assert_equal true, text.include?("event.name=job.failed")
    assert_equal true, text.include?("exception.type=RuntimeError")
    assert_equal true, text.include?("exception.type=NotImplementedError")
  end

  # The drain unit is private — the loop is the public entry; an outside
  # caller must not drive a drain directly.
  def test_drain_once_is_private
    blocked = false
    begin
      ActiveJob::Worker.drain_once
    rescue NoMethodError
      blocked = true
    end
    assert_equal true, blocked
  end

  # A failing adapter drain is reported and the next drain still runs —
  # the worker loop must not die with the only draining thread. The
  # second drain raises SystemExit (process control), which stops the
  # loop so the test can finish and proves the loop reached it.
  def test_a_raising_adapter_does_not_stop_the_drain_loop
    ActiveJob.queue_adapter = FailingThenExitingAdapter
    exited = false
    begin
      ActiveJob::Worker.run
    rescue SystemExit
      exited = true
    end
    assert_equal true, exited
    text = @log.messages.join("\n")
    assert_equal true, text.include?("event.name=worker.drain_failed")
    assert_equal true, text.include?("exception.type=NotImplementedError")
    assert_equal true, text.include?("event.name=worker.loop_stopped")
    assert_equal true, text.include?("exception.type=SystemExit")
  end
end

FixtureRunner.run(JobWorkerTest, [
  "test_no_executor_runs_at_the_call_site",
  "test_drain_round_trip_isolates_failures",
  "test_drain_once_is_private",
  "test_a_raising_adapter_does_not_stop_the_drain_loop"
])
