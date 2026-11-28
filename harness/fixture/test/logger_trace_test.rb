require_relative "test_helper"
require_relative "harness_runner"
require_relative "test_database"

# Logger trace correlation: the tracer mirrors the innermost span into
# `Snails::Logger::Context`, and the logger reads that bag without asking
# `Snails.tracer`. The OTLP logs record carries the ids at the top level so a
# backend can join logs to spans.
class LoggerTraceQueueAdapter
  SUBMITTED = []

  def self.enqueue(job_name, work, payload)
    SUBMITTED << [job_name, payload]
  end
end

class LoggerTraceSpanCapture
  def initialize
    @spans = []
  end

  def spans
    @spans
  end

  def deliver(spans)
    spans.each { |span| @spans << span }
  end
end

class LoggerTraceTest < TestBase
  TRACE_ID = "0af7651916cd43dd8448eb211c80319c"
  SPAN_ID = "b7ad6b7169203331"

  def setup
    Snails.logger.transport = nil
    Snails.logger.flush
    Snails.logger.level = :info
    Snails.logger.output = CapturedLog.new
    Snails.tracer.transport = nil
    Snails.tracer.flush
    Snails.tracer.sample_rate = 1.0
    Snails::Tracer::Context.end_trace
  end

  def assert_equal(expected, actual)
    raise("expected #{expected.inspect}, got #{actual.inspect}") unless expected == actual
  end

  def assert_trace(span)
    trace = Snails::Logger::Context.trace
    assert_equal span.trace_id, trace["trace_id"]
    assert_equal span.span_id, trace["span_id"]
    assert_equal 1, trace["trace_flags"]
  end

  # A reused request or job thread must not carry the previous unit's span ids
  # into its first records, so each boundary clears the mirror.
  def test_context_trace_fields_are_cleared_at_request_and_job_boundaries
    Snails::Logger::Context.set_trace(TRACE_ID, SPAN_ID, 1)
    assert_equal TRACE_ID, Snails::Logger::Context.trace["trace_id"]

    Snails::Logger::Context.begin_request
    assert_equal nil, Snails::Logger::Context.trace

    Snails::Logger::Context.set_trace(TRACE_ID, SPAN_ID, 1)
    Snails::Logger::Context.begin_job("TraceJob", 7, 1)
    assert_equal nil, Snails::Logger::Context.trace

    Snails::Logger::Context.set_trace(TRACE_ID, SPAN_ID, 1)
    Snails::Logger::Context.end_job
    assert_equal nil, Snails::Logger::Context.trace
  end

  # Starting a span mirrors its ids, and finishing it restores the parent or
  # clears the bag at the root.
  def test_tracer_mirrors_the_current_span_into_the_logger_context
    Snails.tracer.transport = LoggerTraceSpanCapture.new

    outer = nil
    Snails.tracer.in_span("app.outer") do |span|
      outer = span
      assert_trace(span)

      Snails.tracer.in_span("app.inner") do |child|
        assert_trace(child)
      end

      assert_trace(outer)
    end

    assert_equal nil, Snails::Logger::Context.trace
  end

  # The completed request record is written while the request span is still
  # current, so it carries the request span's ids and the request id together.
  # The local line exposes the same tags to a human reader.
  def test_request_record_and_local_line_carry_the_trace_and_request_id
    TestDatabase.configure!("logger_trace")
    output = CapturedLog.new
    capture = RecordCapture.new
    Snails.logger.output = output
    Snails.logger.transport = capture
    spans = LoggerTraceSpanCapture.new
    Snails.tracer.transport = spans

    req = Tep::Request.new
    req.verb = "GET"
    req.path = "/up"
    req.raw_path = "/up"
    req.remote_host = +"127.0.0.1"
    Tep::APP.dispatch(req, Tep::Response.new)

    Snails.tracer.flush
    Snails.logger.flush

    request_span = spans.spans[0]
    assert_equal "GET /up", request_span.name
    assert_equal 1, spans.spans.length
    assert_equal 1, capture.records.length
    record = capture.records[0]
    assert_equal "request.completed", record.event
    assert_equal request_span.trace_id, record.trace_id
    assert_equal request_span.span_id, record.span_id
    assert_equal 1, record.trace_flags
    request_id = record.fields["snails.request_id"]
    assert_equal 8, request_id.length

    line = output.messages[0]
    assert_equal true, line.include?("trace_id=" + request_span.trace_id)
    assert_equal true, line.include?("span_id=" + request_span.span_id)
    assert_equal true, line.include?("snails.request_id=" + request_id)
    assert_equal nil, Snails::Logger::Context.trace
  end

  # The logs transport writes traceId/spanId/flags at the logRecord top level,
  # not in attributes, and omits them when the record has no trace.
  def test_otlp_log_record_puts_the_trace_at_the_top_level
    traced = Snails::Logger::Record.new(
      :info, "app.log", "traced",
      trace: { "trace_id" => TRACE_ID, "span_id" => SPAN_ID, "trace_flags" => 1 }
    )
    plain = Snails::Logger::Record.new(:info, "app.log", "plain")

    ActiveJob::EXECUTORS.clear
    ActiveJob.register_executor
    ActiveJob.queue_adapter = LoggerTraceQueueAdapter
    LoggerTraceQueueAdapter::SUBMITTED.clear
    transport = Snails::Logger::OTLPTransport.new(
      endpoint: "https://collector.example.com",
      token: "token"
    )

    transport.deliver([ traced ])
    transport.deliver([ plain ])
    assert_equal 2, LoggerTraceQueueAdapter::SUBMITTED.length
    assert_equal "Snails::LogDeliveryJob", LoggerTraceQueueAdapter::SUBMITTED[0][0]

    traced_log = LoggerTraceQueueAdapter::SUBMITTED[0][1]["resourceLogs"][0]["scopeLogs"][0]["logRecords"][0]
    assert_equal TRACE_ID, traced_log["traceId"]
    assert_equal SPAN_ID, traced_log["spanId"]
    assert_equal 1, traced_log["flags"]

    plain_log = LoggerTraceQueueAdapter::SUBMITTED[1][1]["resourceLogs"][0]["scopeLogs"][0]["logRecords"][0]
    assert_equal false, plain_log.key?("traceId")
    assert_equal false, plain_log.key?("spanId")
    assert_equal false, plain_log.key?("flags")

    traced_keys = traced_log["attributes"].map { |attribute| attribute["key"] }
    assert_equal false, traced_keys.include?("traceId")
    assert_equal false, traced_keys.include?("spanId")
    assert_equal false, traced_keys.include?("flags")
  end
end

FixtureRunner.run(LoggerTraceTest, [
  "test_context_trace_fields_are_cleared_at_request_and_job_boundaries",
  "test_tracer_mirrors_the_current_span_into_the_logger_context",
  "test_request_record_and_local_line_carry_the_trace_and_request_id",
  "test_otlp_log_record_puts_the_trace_at_the_top_level"
])
