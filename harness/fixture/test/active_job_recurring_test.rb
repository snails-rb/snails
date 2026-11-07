require_relative "test_helper"
require_relative "harness_runner"

# The declared job — the shape `recurring` consumes: `job_name`
# (the handler key) plus a class-side `perform`.
class RecurringTickJob < ActiveJob::Base
  def self.job_name = "RecurringTickJob"

  def self.perform(data)
    RecurringSink::RAN << 0
  end
end

class RecurringSink
  RAN = []
end

# ActiveJob recurring (core) — the one-call declaration: `recurring`
# takes the job class and wires the worker-loop beat, and each beat fire
# enqueues the job once per interval (`scheduled_at` — the interval's
# start). Pinned here: the registration record and the beat; the
# once-per-interval enqueue through the selected adapter; a drain-less
# context still runs at the call site; and the default adapter carries
# the recurring half (ProcessQueue delegates to its own enqueue).
class JobRecurringTest < TestBase
  def setup
    ActiveJob::EXECUTORS.clear
    ActiveJob::RECURRING.clear
    ActiveJob::Scheduler::PERIODIC.clear
    UniqueQueueAdapter::KEYS.clear
    UniqueQueueAdapter::SUBMITTED.clear
    RecurringSink::RAN.clear
    ActiveJob.queue_adapter = ActiveJob::ProcessQueue
  end

  def assert_equal(expected, actual, msg = nil)
    raise(msg || "expected #{expected.inspect}, got #{actual.inspect}") unless expected == actual
  end

  # One call records the registration and wires exactly one worker-loop
  # beat carrying the interval.
  def test_recurring_registers_the_beat
    ActiveJob.queue_adapter = UniqueQueueAdapter
    ActiveJob.recurring(RecurringTickJob, 300)
    assert_equal 1, ActiveJob::RECURRING.length
    assert_equal "RecurringTickJob", ActiveJob::RECURRING[0]["name"]
    assert_equal 1, ActiveJob::Scheduler::PERIODIC.length
    assert_equal 300, ActiveJob::Scheduler::PERIODIC[0]["interval"]
  end

  # A rejected interval registers nothing: no half-recorded RECURRING
  # entry and no worker-loop beat.
  def test_a_non_positive_interval_registers_nothing
    zero = false
    begin
      ActiveJob.recurring(RecurringTickJob, 0)
    rescue ArgumentError
      zero = true
    end
    assert_equal true, zero
    assert_equal 0, ActiveJob::RECURRING.length
    assert_equal 0, ActiveJob::Scheduler::PERIODIC.length

    negative = false
    begin
      ActiveJob.recurring(RecurringTickJob, -1)
    rescue ArgumentError
      negative = true
    end
    assert_equal true, negative
    assert_equal 0, ActiveJob::RECURRING.length
    assert_equal 0, ActiveJob::Scheduler::PERIODIC.length
  end

  # Driving the beat enqueues the job with the interval's `scheduled_at`
  # through the selected adapter; a second fire in the same interval is a
  # no-op (the adapter's unique key), so nothing runs at enqueue time.
  def test_beat_enqueues_once_per_interval
    ActiveJob.queue_adapter = UniqueQueueAdapter
    ActiveJob.recurring(RecurringTickJob, 300)
    ActiveJob.register_executor
    ActiveJob::Scheduler::PERIODIC[0]["work"].call
    assert_equal 1, UniqueQueueAdapter::SUBMITTED.length
    assert_equal ActiveJob.scheduled_at_for(300), UniqueQueueAdapter::SUBMITTED[0]["scheduled_at"]
    assert_equal 0, RecurringSink::RAN.length

    ActiveJob::Scheduler::PERIODIC[0]["work"].call
    assert_equal 1, UniqueQueueAdapter::SUBMITTED.length
    assert_equal 0, RecurringSink::RAN.length
  end

  # With no executor registered the work runs at the call site — the
  # `enqueue` rule (a queue nobody drains is a silent loss).
  def test_no_executor_runs_at_the_call_site
    ActiveJob.queue_adapter = UniqueQueueAdapter
    ActiveJob.recurring(RecurringTickJob, 300)
    ActiveJob::Scheduler::PERIODIC[0]["work"].call
    assert_equal 1, RecurringSink::RAN.length
    assert_equal 0, UniqueQueueAdapter::SUBMITTED.length
  end

  # The default adapter carries the recurring half too: `enqueue_once`
  # queues the work exactly like `enqueue` and answers true (this call
  # enqueued).
  def test_process_queue_carries_enqueue_once
    ActiveJob.register_executor
    enqueued = ActiveJob::ProcessQueue.enqueue_once("TickJob", -> { RecurringSink::RAN << 0 }, nil, ActiveJob.scheduled_at_for(300))
    assert_equal true, enqueued
    assert_equal 1, ActiveJob::ProcessQueue.pending_count
    ActiveJob::ProcessQueue.drain
    assert_equal 1, RecurringSink::RAN.length
  end

  # `enqueue_once` answers whether this call enqueued the job: true for
  # the first call in a slot, false for the duplicate (the store-backed
  # unique-key contract).
  def test_enqueue_once_answers_whether_it_enqueued
    ActiveJob.register_executor
    slot = ActiveJob.scheduled_at_for(300)
    first = UniqueQueueAdapter.enqueue_once("TickJob", -> { RecurringSink::RAN << 0 }, nil, slot)
    second = UniqueQueueAdapter.enqueue_once("TickJob", -> { RecurringSink::RAN << 0 }, nil, slot)
    assert_equal true, first
    assert_equal false, second
  end
end

# An app-defined adapter carrying the recurring half: `enqueue_once`
# records the interval's `scheduled_at` and ignores repeats — the
# unique-key shape every store-backed adapter implements (the harness
# pins it). Its signature is pinned by the sidecar beside this file.
class UniqueQueueAdapter
  KEYS = []
  SUBMITTED = []

  def self.enqueue_once(job_name, work, payload, scheduled_at)
    key = job_name + "@" + scheduled_at.to_s
    found = false
    KEYS.each { |element| found = true if element == key }
    return false if found

    KEYS << key
    SUBMITTED << { "job_name" => job_name, "work" => work, "scheduled_at" => scheduled_at }
    true
  end
end

FixtureRunner.run(JobRecurringTest, [
  "test_recurring_registers_the_beat",
  "test_a_non_positive_interval_registers_nothing",
  "test_beat_enqueues_once_per_interval",
  "test_no_executor_runs_at_the_call_site",
  "test_process_queue_carries_enqueue_once",
  "test_enqueue_once_answers_whether_it_enqueued"
])
