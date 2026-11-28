require_relative "test_helper"
require_relative "harness_runner"

# Job tracing on the process queue: enqueue is a producer span, the drain is a
# consumer span, and the log delivery job is left out of both.
class JobTraceSink
  RAN = []
end

class JobTraceSinkJob < ActiveJob::Base
  def self.perform(data)
    JobTraceSink::RAN << (data.nil? ? 0 : data["n"])
  end
end

class JobTraceBoomJob < ActiveJob::Base
  def self.perform(data)
    raise "boom"
  end
end

class JobTraceTest < TestBase
  class SpanCapture
    def initialize
      @spans = []
    end

    def spans
      @spans
    end

    def deliver(spans)
      spans.each { |span| @spans.push(span) }
    end
  end

  def setup
    Snails.logger.transport = nil
    Snails.logger.output = CapturedLog.new
    Snails.logger.level = :info
    Snails::Tracer::Context.end_trace
    Snails.tracer.transport = nil
    Snails.tracer.flush
    Snails.tracer.sample_rate = 1.0
    ActiveJob::EXECUTORS.clear
    ActiveJob.register_executor
    ActiveJob.queue_adapter = ActiveJob::ProcessQueue
    ActiveJob::ProcessQueue::PENDING.clear
    ActiveJob::ProcessQueue::OVERFLOW_REPORTED[0] = false
    JobTraceSink::RAN.clear
  end

  def assert_equal(expected, actual)
    raise("expected #{expected.inspect}, got #{actual.inspect}") unless expected == actual
  end

  def enable_tracing
    capture = SpanCapture.new
    Snails.tracer.transport = capture
    capture
  end

  def flush_spans(capture)
    Snails.tracer.flush
    capture.spans
  end

  def find_span(spans, name)
    i = 0
    while i < spans.length
      return spans[i] if spans[i].name == name
      i += 1
    end
    nil
  end

  # An enqueue is one producer span with the messaging attributes and the job
  # key; the job stays queued.
  def test_enqueue_creates_a_producer_span
    capture = enable_tracing
    ActiveJob.enqueue(JobTraceSinkJob, { "n" => 1 })
    spans = flush_spans(capture)

    producer = find_span(spans, "JobTraceSinkJob publish")
    assert_equal false, producer.nil?
    assert_equal :producer, producer.kind
    assert_equal :ok, producer.status
    attributes = producer.attributes
    assert_equal "snails", attributes["messaging.system"]
    assert_equal "JobTraceSinkJob", attributes["messaging.destination.name"]
    assert_equal "publish", attributes["messaging.operation"]
    assert_equal "JobTraceSinkJob", attributes["snails.job.name"]
    assert_equal 0, JobTraceSink::RAN.length
    assert_equal 1, ActiveJob::ProcessQueue.pending_count
    ActiveJob::ProcessQueue::PENDING.clear
  end

  # A delayed enqueue is a producer span too.
  def test_schedule_creates_a_producer_span
    capture = enable_tracing
    ActiveJob.schedule(JobTraceSinkJob, Time.now + 60, { "n" => 2 })
    spans = flush_spans(capture)

    producer = find_span(spans, "JobTraceSinkJob publish")
    assert_equal false, producer.nil?
    assert_equal :producer, producer.kind
    assert_equal :ok, producer.status
    assert_equal 1, ActiveJob::ProcessQueue.pending_count
    ActiveJob::ProcessQueue::PENDING.clear
  end

  # The log delivery job is not a producer span; its work would feed the
  # delivery loop its own span belongs to.
  def test_enqueue_skips_a_delivery_job
    capture = enable_tracing
    ActiveJob.enqueue(Snails::LogDeliveryJob, {})
    spans = flush_spans(capture)
    assert_equal 0, spans.length
    ActiveJob::ProcessQueue::PENDING.clear
  end

  # A drain creates a consumer span for the body; the producer span and the
  # consumer span are separate traces in this stage.
  def test_drain_creates_a_consumer_span
    capture = enable_tracing
    ActiveJob.enqueue(JobTraceSinkJob, { "n" => 3 })
    ActiveJob::ProcessQueue.drain
    spans = flush_spans(capture)

    producer = find_span(spans, "JobTraceSinkJob publish")
    consumer = find_span(spans, "JobTraceSinkJob process")
    assert_equal false, producer.nil?
    assert_equal false, consumer.nil?
    assert_equal :consumer, consumer.kind
    assert_equal :ok, consumer.status
    assert_equal false, producer.trace_id == consumer.trace_id
    assert_equal nil, consumer.parent_span_id
    attributes = consumer.attributes
    assert_equal "snails", attributes["messaging.system"]
    assert_equal "JobTraceSinkJob", attributes["messaging.destination.name"]
    assert_equal "process", attributes["messaging.operation"]
    assert_equal "JobTraceSinkJob", attributes["snails.job.name"]
    assert_equal true, attributes["snails.job.id"].is_a?(Integer)
    assert_equal 1, attributes["snails.job.attempt"]
    assert_equal nil, attributes["snails.queue.wait_ms"]
    assert_equal [3], JobTraceSink::RAN
  end

  # A raising body becomes an error status and an exception event before the
  # drain records the failure.
  def test_job_exception_is_a_consumer_error
    capture = enable_tracing
    ActiveJob.enqueue(JobTraceBoomJob, nil)
    ActiveJob::ProcessQueue.drain
    spans = flush_spans(capture)

    consumer = find_span(spans, "JobTraceBoomJob process")
    assert_equal false, consumer.nil?
    assert_equal :error, consumer.status
    assert_equal 1, consumer.events.length
    assert_equal "exception", consumer.events[0]["name"]
    assert_equal "RuntimeError", consumer.events[0]["attributes"]["exception.type"]
    assert_equal "boom", consumer.events[0]["attributes"]["exception.message"]
  end

  # The log delivery job's run is not a consumer span either.
  def test_drain_skips_a_delivery_job
    capture = enable_tracing
    ActiveJob.enqueue(Snails::LogDeliveryJob, {})
    ActiveJob::ProcessQueue.drain
    spans = flush_spans(capture)
    assert_equal 0, spans.length
  end

  # The trace delivery job is excluded from the automatic job span for the
  # same reason: its run would feed the trace pipeline it delivers.
  def test_drain_skips_a_trace_delivery_job
    capture = enable_tracing
    ActiveJob.enqueue(Snails::TraceDeliveryJob, {})
    ActiveJob::ProcessQueue.drain
    spans = flush_spans(capture)
    assert_equal 0, spans.length
  end
end

FixtureRunner.run(JobTraceTest, [
  "test_enqueue_creates_a_producer_span",
  "test_schedule_creates_a_producer_span",
  "test_enqueue_skips_a_delivery_job",
  "test_drain_creates_a_consumer_span",
  "test_job_exception_is_a_consumer_error",
  "test_drain_skips_a_delivery_job",
  "test_drain_skips_a_trace_delivery_job"
])
