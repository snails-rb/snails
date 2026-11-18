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

# ActiveJob recurring (core) — the one-call declaration: `recurring` takes
# the job class with either an interval or a cron expression and wires one
# periodic callback; each run enqueues the job with the occurrence time as
# `scheduled_at`. Pinned here: both registration forms and their rejection; the
# once-per-occurrence enqueue through the selected adapter; the next-occurrence
# start (a missed occurrence is not caught up); a drain-less context still runs
# at the call site; and the default adapter carries the recurring half
# (ProcessQueue delegates to its own enqueue).
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

  # One call records the registration and wires exactly one periodic callback
  # carrying the interval.
  def test_recurring_registers_the_callback
    ActiveJob.queue_adapter = UniqueQueueAdapter
    ActiveJob.recurring(RecurringTickJob, 300)
    assert_equal 1, ActiveJob::RECURRING.length
    assert_equal "RecurringTickJob", ActiveJob::RECURRING[0]["name"]
    assert_equal 1, ActiveJob::Scheduler::PERIODIC.length
    assert_equal 300, ActiveJob::Scheduler::PERIODIC[0]["interval"]
  end

  # A duration interval reads the same as seconds: `5.minutes` registers 300.
  def test_recurring_accepts_a_duration_interval
    ActiveJob.queue_adapter = UniqueQueueAdapter
    ActiveJob.recurring(RecurringTickJob, 5.minutes)
    assert_equal 1, ActiveJob::RECURRING.length
    assert_equal 300, ActiveJob::Scheduler::PERIODIC[0]["interval"]
  end

  # A rejected interval registers nothing: no half-recorded RECURRING
  # entry and no registered callback.
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

  # One call with a cron expression records the parsed expression and wires
  # exactly one callback carrying it.
  def test_recurring_registers_a_cron_schedule
    ActiveJob.queue_adapter = UniqueQueueAdapter
    ActiveJob.recurring(RecurringTickJob, schedule: "0 6 * * *")
    assert_equal 1, ActiveJob::RECURRING.length
    assert_equal "RecurringTickJob", ActiveJob::RECURRING[0]["name"]
    assert_equal nil, ActiveJob::RECURRING[0]["interval"]
    assert_equal true, ActiveJob::RECURRING[0]["cron"] != nil
    assert_equal 1, ActiveJob::Scheduler::PERIODIC.length
    assert_equal nil, ActiveJob::Scheduler::PERIODIC[0]["interval"]
    assert_equal true, ActiveJob::Scheduler::PERIODIC[0]["cron"] != nil
  end

  # Both forms at once are a declaration mistake: nothing is registered.
  def test_recurring_rejects_both_forms
    both = false
    begin
      ActiveJob.recurring(RecurringTickJob, 300, schedule: "0 6 * * *")
    rescue ArgumentError
      both = true
    end
    assert_equal true, both
    assert_equal 0, ActiveJob::RECURRING.length
    assert_equal 0, ActiveJob::Scheduler::PERIODIC.length
  end

  # Neither form is a declaration mistake too: nothing is registered.
  def test_recurring_requires_a_form
    missing = false
    begin
      ActiveJob.recurring(RecurringTickJob)
    rescue ArgumentError
      missing = true
    end
    assert_equal true, missing
    assert_equal 0, ActiveJob::RECURRING.length
    assert_equal 0, ActiveJob::Scheduler::PERIODIC.length
  end

  # A cron expression the grammar rejects fails when the schedule is
  # declared, leaving no entry behind.
  def test_recurring_rejects_an_unreadable_schedule
    unreadable = false
    begin
      ActiveJob.recurring(RecurringTickJob, schedule: "0 6 * *")
    rescue ArgumentError
      unreadable = true
    end
    assert_equal true, unreadable
    assert_equal 0, ActiveJob::RECURRING.length
    assert_equal 0, ActiveJob::Scheduler::PERIODIC.length
  end

  # Driving the callback enqueues the job with the interval window's start
  # through the selected adapter. The first pass adopts the covering window
  # without enqueuing; a later pass in the same window is a no-op, and the next
  # window enqueues once.
  def test_callback_enqueues_once_per_interval
    ActiveJob.queue_adapter = UniqueQueueAdapter
    ActiveJob.recurring(RecurringTickJob, 300)
    ActiveJob.register_executor
    now = Time.utc(2026, 11, 18, 5, 0, 0).to_i
    ActiveJob::Scheduler.run_periodic(now)
    assert_equal 0, UniqueQueueAdapter::SUBMITTED.length

    ActiveJob::Scheduler.run_periodic(now + 10)
    assert_equal 0, UniqueQueueAdapter::SUBMITTED.length

    ActiveJob::Scheduler.run_periodic(now + 300)
    assert_equal 1, UniqueQueueAdapter::SUBMITTED.length
    assert_equal ActiveJob.scheduled_at_for(300, Time.at(now + 300)), UniqueQueueAdapter::SUBMITTED[0]["scheduled_at"]
    assert_equal 0, RecurringSink::RAN.length

    ActiveJob::Scheduler.run_periodic(now + 305)
    assert_equal 1, UniqueQueueAdapter::SUBMITTED.length

    ActiveJob::Scheduler.run_periodic(now + 600)
    assert_equal 2, UniqueQueueAdapter::SUBMITTED.length
  end

  # A cron registration starts at the next occurrence: the first pass adopts the
  # covering one without enqueuing, and 06:00 enqueues that occurrence.
  def test_cron_callback_enqueues_the_next_occurrence
    ActiveJob.queue_adapter = UniqueQueueAdapter
    ActiveJob.recurring(RecurringTickJob, schedule: "0 6 * * *")
    ActiveJob.register_executor

    ActiveJob::Scheduler.run_periodic(Time.utc(2026, 11, 18, 5, 0, 0).to_i)
    assert_equal 0, UniqueQueueAdapter::SUBMITTED.length

    ActiveJob::Scheduler.run_periodic(Time.utc(2026, 11, 18, 5, 30, 0).to_i)
    assert_equal 0, UniqueQueueAdapter::SUBMITTED.length

    ActiveJob::Scheduler.run_periodic(Time.utc(2026, 11, 18, 6, 0, 0).to_i)
    assert_equal 1, UniqueQueueAdapter::SUBMITTED.length
    assert_equal Time.utc(2026, 11, 18, 6, 0, 0), UniqueQueueAdapter::SUBMITTED[0]["scheduled_at"]

    ActiveJob::Scheduler.run_periodic(Time.utc(2026, 11, 18, 6, 1, 0).to_i)
    assert_equal 1, UniqueQueueAdapter::SUBMITTED.length

    ActiveJob::Scheduler.run_periodic(Time.utc(2026, 11, 19, 6, 0, 0).to_i)
    assert_equal 2, UniqueQueueAdapter::SUBMITTED.length
    assert_equal Time.utc(2026, 11, 19, 6, 0, 0), UniqueQueueAdapter::SUBMITTED[1]["scheduled_at"]
  end

  # With no executor registered the work runs at the call site — the
  # `enqueue` rule (a queue nobody drains is a silent loss).
  def test_no_executor_runs_at_the_call_site
    ActiveJob.queue_adapter = UniqueQueueAdapter
    ActiveJob.recurring(RecurringTickJob, 300)
    ActiveJob::Scheduler::PERIODIC[0]["work"].call(Time.now.to_i)
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
  "test_recurring_registers_the_callback",
  "test_recurring_accepts_a_duration_interval",
  "test_a_non_positive_interval_registers_nothing",
  "test_recurring_registers_a_cron_schedule",
  "test_recurring_rejects_both_forms",
  "test_recurring_requires_a_form",
  "test_recurring_rejects_an_unreadable_schedule",
  "test_callback_enqueues_once_per_interval",
  "test_cron_callback_enqueues_the_next_occurrence",
  "test_no_executor_runs_at_the_call_site",
  "test_process_queue_carries_enqueue_once",
  "test_enqueue_once_answers_whether_it_enqueued"
])
