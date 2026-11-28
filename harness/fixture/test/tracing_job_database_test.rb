require_relative "test_helper"
require_relative "harness_runner"
require_relative "test_database"

# Job tracing on the database queue: the consumer span carries the row wait,
# a raising body and a delivery failure both close it as error, and the log
# delivery job is left out.
class JobTraceDbSink
  RAN = []
end

class JobTraceDbSinkJob < ActiveJob::Base
  def self.perform(data)
    JobTraceDbSink::RAN << (data.nil? ? 0 : data["n"])
  end
end

class JobTraceDbBoomJob < ActiveJob::Base
  def self.perform(data)
    raise "boom"
  end
end

class JobTraceDatabaseTest < TestBase
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
    TestDatabase.configure!("tracing_job_database")
    TestDatabase.load_queue_schema!
    ActiveJob::EXECUTORS.clear
    ActiveJob.register_executor
    ActiveJob.queue_adapter = ActiveJob::DatabaseQueue
    ActiveJob::DatabaseQueue::LAST_DRAIN_AT[0] = 0
    ActiveJob::DatabaseQueue::LAST_DRAIN_WAS_FULL[0] = false
    JobTraceDbSink::RAN.clear
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

  def insert_row(name, payload, scheduled_at)
    now = Time.now.utc
    Sqlx::Base.write(
      "INSERT INTO snails_queue_jobs (name, payload, status, scheduled_at, attempts, created_at, updated_at) " +
      "VALUES (?, ?, 'pending', ?, 0, ?, ?)",
      [ name, payload, scheduled_at, now, now ]
    )
  end

  # A claimed row's consumer span carries the wait from its run time to the
  # start, the row id, and the attempt count.
  def test_database_consumer_carries_the_row_wait
    insert_row("JobTraceDbSinkJob", '{"n":1}', Time.now.utc - 1)
    capture = enable_tracing
    ActiveJob::DatabaseQueue.drain
    spans = flush_spans(capture)

    consumer = find_span(spans, "JobTraceDbSinkJob process")
    assert_equal false, consumer.nil?
    assert_equal :consumer, consumer.kind
    assert_equal :ok, consumer.status
    attributes = consumer.attributes
    assert_equal "snails", attributes["messaging.system"]
    assert_equal "process", attributes["messaging.operation"]
    assert_equal "JobTraceDbSinkJob", attributes["snails.job.name"]
    assert_equal true, attributes["snails.job.id"].is_a?(Integer)
    assert_equal 1, attributes["snails.job.attempt"]
    assert_equal true, attributes["snails.queue.wait_ms"] > 0.0
    assert_equal [1], JobTraceDbSink::RAN
  end

  # A raising body closes the consumer span as error and leaves an exception
  # event before the row is marked failed.
  def test_database_body_exception_is_a_consumer_error
    insert_row("JobTraceDbBoomJob", nil, Time.now.utc)
    capture = enable_tracing
    ActiveJob::DatabaseQueue.drain
    spans = flush_spans(capture)

    consumer = find_span(spans, "JobTraceDbBoomJob process")
    assert_equal false, consumer.nil?
    assert_equal :error, consumer.status
    assert_equal 1, consumer.events.length
    assert_equal "RuntimeError", consumer.events[0]["attributes"]["exception.type"]
    assert_equal "boom", consumer.events[0]["attributes"]["exception.message"]
  end

  # A missing handler is a delivery failure, but the run unit failed, so the
  # consumer span is error too.
  def test_database_handler_not_found_is_a_consumer_error
    insert_row("MissingJobTraceClass", nil, Time.now.utc)
    capture = enable_tracing
    ActiveJob::DatabaseQueue.drain
    spans = flush_spans(capture)

    consumer = find_span(spans, "MissingJobTraceClass process")
    assert_equal false, consumer.nil?
    assert_equal :error, consumer.status
    assert_equal 1, consumer.events.length
    assert_equal "NameError", consumer.events[0]["attributes"]["exception.type"]
  end

  # An unreadable payload is the other delivery failure; its consumer span is
  # error as well.
  def test_database_payload_unreadable_is_a_consumer_error
    insert_row("JobTraceDbSinkJob", "{bad", Time.now.utc)
    capture = enable_tracing
    ActiveJob::DatabaseQueue.drain
    spans = flush_spans(capture)

    consumer = find_span(spans, "JobTraceDbSinkJob process")
    assert_equal false, consumer.nil?
    assert_equal :error, consumer.status
    assert_equal 1, consumer.events.length
    assert_equal "ArgumentError", consumer.events[0]["attributes"]["exception.type"]
  end

  # The log delivery job's DB run has no consumer span; queue bookkeeping DB
  # spans may still exist.
  def test_database_delivery_job_has_no_consumer_span
    insert_row("Snails::LogDeliveryJob", "{}", Time.now.utc)
    capture = enable_tracing
    ActiveJob::DatabaseQueue.drain
    spans = flush_spans(capture)

    assert_equal nil, find_span(spans, "Snails::LogDeliveryJob process")
  end
end

FixtureRunner.run(JobTraceDatabaseTest, [
  "test_database_consumer_carries_the_row_wait",
  "test_database_body_exception_is_a_consumer_error",
  "test_database_handler_not_found_is_a_consumer_error",
  "test_database_payload_unreadable_is_a_consumer_error",
  "test_database_delivery_job_has_no_consumer_span"
])
