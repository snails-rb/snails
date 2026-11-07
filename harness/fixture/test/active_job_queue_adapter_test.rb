require_relative "test_helper"
require_relative "harness_runner"
require_relative "test_database"

# The job bodies — they record a run in the marks table, so a case can
# tell "the dispatch reached the adapter's drain" from "it did not".
class AdapterMarkJob < ActiveJob::Base
  def self.perform(data)
    Sqlx::Database.exec("INSERT INTO marks (n) VALUES (1)")
  end
end

# The payload shape beside it: `perform` receives the payload as its
# argument and writes through the decoded value.
class AdapterPayloadJob < ActiveJob::Base
  def self.perform(data)
    Sqlx::Database.exec("INSERT INTO marks (n) VALUES (" + data["n"].to_s + ")")
  end
end

# The queue-bound cases use a body with no DB write: the run mark proves the
# accepted entries still drain after a refusal, and filling the queue does not
# touch SQLite 1,000 times.
class QueueLimitJob < ActiveJob::Base
  RAN = []

  def self.perform(data)
    RAN << 1
  end
end

# ActiveJob queue adapter (core) — the slot, the adapter interface, and
# the loop protocol the worker drives. Pinned here: with no selection the
# default is the process-local queue; `queue_adapter=` takes any class —
# an app-defined adapter included — and every hand-off goes through the
# slot (`enqueue` derives the name and the work from the job class); the
# protocol (`drain_due?` answers, `drain` runs under the caller's lease)
# dispatches through the slot for
# both the default and the app adapter (the class-value dispatch form).
class JobQueueAdapterTest < TestBase
  def setup
    TestDatabase.configure!("active_job_queue_adapter")
    TestDatabase.drop_tables!("marks")
    TestDatabase.exec("CREATE TABLE marks (n INTEGER)")
    ActiveJob::EXECUTORS.clear
    ActiveJob.queue_adapter = ActiveJob::ProcessQueue
    ActiveJob::ProcessQueue::PENDING.clear
    # A direct PENDING clear bypasses drain's re-arm; reset the one-shot
    # warning so each case starts a fresh overflow episode.
    ActiveJob::ProcessQueue::OVERFLOW_REPORTED[0] = false
    SinkQueueAdapter::SUBMITTED.clear
    QueueLimitJob::RAN.clear
    @capture = CapturedLog.new
    Snails.logger.output = @capture
    Snails.logger.formatter = MessageOnlyFormatter.new
    # The queue-bound case enqueues a thousand jobs. Job lifecycle records are
    # noise here, and the overflow warning is local (`report_local`) so it is
    # written regardless of the level.
    Snails.logger.level = :warn
  end

  def assert_equal(expected, actual, msg = nil)
    raise(msg || "expected #{expected.inspect}, got #{actual.inspect}") unless expected == actual
  end

  def marks
    rows = Sqlx::Base.rows_by_sql("SELECT COUNT(*) AS total FROM marks")
    rows[0]["total"].to_i
  end

  # One worker-loop pass — the body of the drain loop without
  # the sleep: drain through the slot under the loop's own
  # Sqlx::Database lease.
  def run_loop_once
    if ActiveJob.queue_adapter.drain_due?
      Sqlx::Database.with_connection { ActiveJob.queue_adapter.drain }
    end
  end

  # With no selection the slot resolves to the process-local queue:
  # enqueue lands in `PENDING` and nothing runs.
  def test_default_adapter_is_the_process_queue
    ActiveJob.register_executor
    ActiveJob.enqueue(AdapterMarkJob)
    assert_equal 1, ActiveJob::ProcessQueue.pending_count
    assert_equal 0, marks
  end

  # The open setter takes an app-defined adapter class: the same enqueue
  # lands in its own store, the process-local queue stays empty, and
  # nothing runs before the adapter's drain.
  def test_app_adapter_is_selected_through_the_slot
    ActiveJob.queue_adapter = SinkQueueAdapter
    ActiveJob.register_executor
    ActiveJob.enqueue(AdapterMarkJob, { "n" => 2 })
    assert_equal 0, ActiveJob::ProcessQueue.pending_count
    assert_equal 1, SinkQueueAdapter::SUBMITTED.length
    entry = SinkQueueAdapter::SUBMITTED[0]
    assert_equal "AdapterMarkJob", entry["job_name"]
    assert_equal 0, marks
  end

  # Reselecting `ProcessQueue` restores the default path — the slot is a
  # plain overwrite, not a one-way switch.
  def test_reselecting_the_process_queue
    ActiveJob.queue_adapter = SinkQueueAdapter
    ActiveJob.queue_adapter = ActiveJob::ProcessQueue
    ActiveJob.register_executor
    ActiveJob.enqueue(AdapterMarkJob)
    assert_equal 1, ActiveJob::ProcessQueue.pending_count
    assert_equal 0, SinkQueueAdapter::SUBMITTED.length
  end

  # The loop protocol on the default adapter: a pass with work waiting
  # drains it under the loop's lease.
  def test_loop_protocol_runs_a_process_job
    ActiveJob.register_executor
    ActiveJob.enqueue(AdapterMarkJob)
    run_loop_once
    assert_equal 1, marks
    assert_equal 0, ActiveJob::ProcessQueue.pending_count
  end

  # Payload jobs ride the same loop: the queued proc calls the job's
  # `perform` with the payload, so the drain rebuilds the arguments.
  def test_loop_protocol_runs_a_payload_job
    ActiveJob.register_executor
    ActiveJob.enqueue(AdapterPayloadJob, { "n" => 3 })
    run_loop_once
    assert_equal 1, marks
  end

  # The loop protocol on the app adapter: the same pass drives it through
  # the slot — an app adapter owns its drain interval and its drain body.
  def test_loop_protocol_runs_an_app_adapter_job
    ActiveJob.queue_adapter = SinkQueueAdapter
    ActiveJob.register_executor
    ActiveJob.enqueue(AdapterMarkJob)
    assert_equal 0, marks
    run_loop_once
    assert_equal 1, marks
    assert_equal 0, SinkQueueAdapter::SUBMITTED.length
  end

  # Schedule routes through the slot with its run time: the app adapter
  # records the delayed submission (nothing runs before its drain).
  def test_schedule_hands_the_run_time_to_the_adapter
    ActiveJob.queue_adapter = SinkQueueAdapter
    ActiveJob.register_executor
    at = Time.now.utc + 900
    ActiveJob.schedule(AdapterMarkJob, at)
    assert_equal 1, SinkQueueAdapter::SUBMITTED.length
    entry = SinkQueueAdapter::SUBMITTED[0]
    assert_equal "AdapterMarkJob", entry["job_name"]
    assert_equal at, entry["scheduled_at"]
    assert_equal 0, marks
  end

  # A scheduled job waits: a pass before its time drains nothing and
  # leaves it queued.
  def test_a_scheduled_job_waits_for_its_time
    ActiveJob.register_executor
    ActiveJob.schedule(AdapterMarkJob, Time.now.utc + 3600)
    run_loop_once
    assert_equal 0, marks
    assert_equal 1, ActiveJob::ProcessQueue.pending_count
  end

  # Once the clock passes the run time the same pass drains it.
  def test_a_due_scheduled_job_runs_on_the_drain
    ActiveJob.register_executor
    ActiveJob.schedule(AdapterMarkJob, Time.now.utc - 1)
    run_loop_once
    assert_equal 1, marks
    assert_equal 0, ActiveJob::ProcessQueue.pending_count
  end

  def fill_process_queue(n)
    i = 0
    while i < n
      ActiveJob::ProcessQueue.enqueue("QueueLimitJob", -> { QueueLimitJob::RAN << 1 }, nil)
      i = i + 1
    end
  end

  # The process queue is bounded: at `MAX_PENDING` the next job is refused,
  # the accepted jobs still drain, and the refusal is one local warning (a
  # record would enqueue another delivery job into the full queue).
  def test_the_process_queue_drops_new_jobs_at_the_limit
    fill_process_queue(ActiveJob::ProcessQueue::MAX_PENDING)
    assert_equal ActiveJob::ProcessQueue::MAX_PENDING, ActiveJob::ProcessQueue.pending_count

    ActiveJob::ProcessQueue.enqueue("QueueLimitJob", -> { QueueLimitJob::RAN << 1 }, nil)
    assert_equal ActiveJob::ProcessQueue::MAX_PENDING, ActiveJob::ProcessQueue.pending_count
    assert_equal 1, @capture.messages.length
    assert_equal true, @capture.messages[0].include?("process queue is full")
    assert_equal 0, QueueLimitJob::RAN.length

    ran = ActiveJob::ProcessQueue.drain
    assert_equal ActiveJob::ProcessQueue::MAX_PENDING, ran
    assert_equal ActiveJob::ProcessQueue::MAX_PENDING, QueueLimitJob::RAN.length
  end

  # The warning is one line per overflow episode: repeated refusals stay
  # quiet, and a drain that brings the queue back under half re-arms it.
  def test_the_full_queue_warning_repeats_only_after_the_queue_drains
    fill_process_queue(ActiveJob::ProcessQueue::MAX_PENDING)
    ActiveJob::ProcessQueue.enqueue("QueueLimitJob", -> { QueueLimitJob::RAN << 1 }, nil)
    ActiveJob::ProcessQueue.enqueue("QueueLimitJob", -> { QueueLimitJob::RAN << 1 }, nil)
    assert_equal 1, @capture.messages.length

    ActiveJob::ProcessQueue.drain
    fill_process_queue(ActiveJob::ProcessQueue::MAX_PENDING)
    ActiveJob::ProcessQueue.enqueue("QueueLimitJob", -> { QueueLimitJob::RAN << 1 }, nil)
    assert_equal 2, @capture.messages.length
  end

  # `enqueue_once` (the recurring half) forwards the refusal so a beat does
  # not claim a run that was dropped.
  def test_enqueue_once_answers_false_when_the_queue_is_full
    fill_process_queue(ActiveJob::ProcessQueue::MAX_PENDING)
    assert_equal false, ActiveJob::ProcessQueue.enqueue_once(
      "QueueLimitJob", -> { QueueLimitJob::RAN << 1 }, nil, Time.now.utc
    )
    assert_equal ActiveJob::ProcessQueue::MAX_PENDING, ActiveJob::ProcessQueue.pending_count
  end

  # The overflow warning is local: if it were a log record, sending it would
  # enqueue another delivery job into the queue that is already full.
  def test_the_full_queue_warning_does_not_enter_the_transport
    records = RecordCapture.new
    Snails.logger.transport = records
    begin
      fill_process_queue(ActiveJob::ProcessQueue::MAX_PENDING)
      ActiveJob::ProcessQueue.enqueue("QueueLimitJob", -> { QueueLimitJob::RAN << 1 }, nil)
      assert_equal 1, @capture.messages.length
      assert_equal 0, records.records.length
    ensure
      Snails.logger.transport = nil
    end
  end
end

# An app-defined adapter — the extension the open slot exists for.
# `enqueue` stores the three hand-off values; `drain` runs the stored
# work, so the job body's mark proves the dispatch path reached here.
class SinkQueueAdapter
  SUBMITTED = []

  def self.enqueue(job_name, work, payload)
    SUBMITTED << { "job_name" => job_name, "work" => work, "payload" => payload }
  end

  def self.enqueue_at(job_name, work, payload, scheduled_at)
    SUBMITTED << { "job_name" => job_name, "work" => work, "payload" => payload, "scheduled_at" => scheduled_at }
  end

  def self.drain_due?
    SUBMITTED.length > 0
  end

  def self.drain
    ran = 0
    while SUBMITTED.length > 0
      entry = SUBMITTED.shift
      entry["work"].call
      ran = ran + 1
    end
    ran
  end
end

FixtureRunner.run(JobQueueAdapterTest, [
  "test_default_adapter_is_the_process_queue",
  "test_app_adapter_is_selected_through_the_slot",
  "test_reselecting_the_process_queue",
  "test_loop_protocol_runs_a_process_job",
  "test_loop_protocol_runs_a_payload_job",
  "test_loop_protocol_runs_an_app_adapter_job",
  "test_schedule_hands_the_run_time_to_the_adapter",
  "test_a_scheduled_job_waits_for_its_time",
  "test_a_due_scheduled_job_runs_on_the_drain",
  "test_the_process_queue_drops_new_jobs_at_the_limit",
  "test_the_full_queue_warning_repeats_only_after_the_queue_drains",
  "test_enqueue_once_answers_false_when_the_queue_is_full",
  "test_the_full_queue_warning_does_not_enter_the_transport"
])
