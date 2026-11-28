require_relative "test_helper"
require_relative "harness_runner"
require_relative "test_database"

# The end-to-end span tree: request → app → DB, request → app → producer, and
# the job run as a separate consumer trace with its own DB child.
TestDatabase.configure!("tracing_tree")

class TracingTreeTest < TestBase
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
    HarnessTraceTreeSink::RAN.clear
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

  def dispatch(path)
    req = Tep::Request.new
    req.verb = "GET"
    req.path = path
    req.raw_path = path
    req.remote_host = +"127.0.0.1"
    Tep::APP.dispatch(req, Tep::Response.new)
  end

  def find_span(spans, name)
    i = 0
    while i < spans.length
      return spans[i] if spans[i].name == name
      i += 1
    end
    nil
  end

  def find_span_by_parent(spans, name, parent_id)
    i = 0
    while i < spans.length
      if spans[i].name == name && spans[i].parent_span_id == parent_id
        return spans[i]
      end
      i += 1
    end
    nil
  end

  # The request span parents the app span; the app span parents the DB read
  # and the producer; the drained job is a separate consumer trace with its
  # own DB child.
  def test_request_app_db_and_job_spans_form_the_tree
    capture = enable_tracing
    dispatch("/trace-tree-probe")
    ActiveJob::ProcessQueue.drain
    spans = flush_spans(capture)

    request = find_span(spans, "GET /trace-tree-probe")
    app = find_span(spans, "app.work")
    producer = find_span(spans, "HarnessTraceTreeJob publish")
    consumer = find_span(spans, "HarnessTraceTreeJob process")
    assert_equal false, request.nil?
    assert_equal false, app.nil?
    assert_equal false, producer.nil?
    assert_equal false, consumer.nil?

    assert_equal :server, request.kind
    assert_equal nil, request.parent_span_id
    assert_equal :internal, app.kind
    assert_equal request.span_id, app.parent_span_id
    assert_equal request.trace_id, app.trace_id
    assert_equal "value", app.attributes["app.key"]

    request_db = find_span_by_parent(spans, "SELECT", app.span_id)
    assert_equal false, request_db.nil?
    assert_equal :client, request_db.kind
    assert_equal app.trace_id, request_db.trace_id
    assert_equal app.span_id, request_db.parent_span_id

    assert_equal :producer, producer.kind
    assert_equal app.span_id, producer.parent_span_id
    assert_equal app.trace_id, producer.trace_id
    assert_equal "HarnessTraceTreeJob", producer.attributes["snails.job.name"]

    assert_equal :consumer, consumer.kind
    assert_equal nil, consumer.parent_span_id
    assert_equal false, consumer.trace_id == request.trace_id
    assert_equal "HarnessTraceTreeJob", consumer.attributes["snails.job.name"]

    consumer_db = find_span_by_parent(spans, "SELECT", consumer.span_id)
    assert_equal false, consumer_db.nil?
    assert_equal :client, consumer_db.kind
    assert_equal consumer.trace_id, consumer_db.trace_id
    assert_equal [1], HarnessTraceTreeSink::RAN
  end
end

FixtureRunner.run(TracingTreeTest, [
  "test_request_app_db_and_job_spans_form_the_tree"
])
