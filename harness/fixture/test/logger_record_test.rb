require_relative "test_helper"
require_relative "harness_runner"

# Snails::Logger record layer (core) — one log event as a field bag, the
# record formatter that renders it locally, the transport slot, and the
# context fields the logger adds. The five level calls render through
# `formatter` when they carry only a message and through `record_formatter`
# when they carry an `event:`, and both shapes reach the transport.
class LoggerRecordTest < TestBase
  # Catches local lines; `flush` belongs to the write path.
  class RecordOutput
    def initialize
      @lines = []
    end

    def lines
      @lines
    end

    def write(line)
      @lines << line
    end

    def flush
    end
  end

  # A transport that keeps every delivered batch.
  class RecordCapture
    def initialize
      @batches = []
    end

    def batches
      @batches
    end

    def deliver(records)
      @batches << records
    end
  end

  # A transport that fails on every call, so the isolation case can count
  # calls and prove the logger did not retry through itself.
  class RaisingTransport
    def initialize
      @calls = 0
    end

    def calls
      @calls
    end

    def deliver(records)
      @calls = @calls + 1
      raise "transport down"
    end
  end

  # Records each call without rendering, so assertions read the record and
  # the progname the logger passed.
  class RecordingRecordFormatter
    def initialize
      @calls = []
    end

    def calls
      @calls
    end

    def call(record, progname)
      @calls << { "record" => record, "progname" => progname }
      "line\n"
    end
  end

  def assert_equal(expected, actual)
    raise("expected #{expected.inspect}, got #{actual.inspect}") unless expected == actual
  end

  def assert_argument_error(work)
    begin
      work.call
    rescue ArgumentError => e
      return e.message
    end
    raise("expected ArgumentError")
  end

  # Renders every line the same, so a case can tell the local render apart
  # from what the transport received.
  class FixedLineFormatter
    def call(severity, time, progname, message)
      "fixed line\n"
    end
  end

  class FixedRecordFormatter
    def call(record, progname)
      "fixed record\n"
    end
  end

  def new_logger(out)
    logger = Snails::Logger.new
    logger.output = out
    logger.level = :debug
    logger
  end

  # A record keeps its time, severity, event, body, and fields as given.
  def test_record_exposes_its_values
    record = Snails::Logger::Record.new(
      :info, "request.completed", "GET /up 200",
      fields: { "http.request.method" => "GET", "http.response.status_code" => 200 },
      time: Time.at(0).utc
    )

    assert_equal :info, record.severity
    assert_equal "request.completed", record.event
    assert_equal "GET /up 200", record.body
    assert_equal "GET", record.fields["http.request.method"]
    assert_equal 200, record.fields["http.response.status_code"]
    assert_equal 2, record.fields.length
    assert_equal Time.at(0).utc, record.time
  end

  # resource is kept separate from record fields and holds service and process
  # attributes.
  def test_record_exposes_resource_fields
    record = Snails::Logger::Record.new(
      :info, "app.log", "x",
      resource: { "service.name" => "example-service", "process.pid" => 1 }
    )

    assert_equal "example-service", record.resource["service.name"]
    assert_equal 1, record.resource["process.pid"]
    assert_equal 0, record.fields.length
  end

  # A value outside the severity vocabulary is rejected at construction time.
  def test_record_rejects_an_unknown_severity
    message = assert_argument_error(-> {
      Snails::Logger::Record.new(:verbose, "app.log", "hello")
    })
    assert_equal true, message.include?(":debug, :info, :warn, :error, :fatal")
  end

  # An event name must be a lowercase dot-separated name.
  def test_record_rejects_bad_event_names
    assert_argument_error(-> { Snails::Logger::Record.new(:info, "Request.Completed", "x") })
    assert_argument_error(-> { Snails::Logger::Record.new(:info, "request", "x") })
    assert_argument_error(-> { Snails::Logger::Record.new(:info, "", "x") })
  end

  # Field names allow only dot-separated identifiers.
  def test_record_rejects_bad_field_names
    assert_argument_error(-> {
      Snails::Logger::Record.new(:info, "app.log", "x", fields: { "bad name" => 1 })
    })
    assert_argument_error(-> {
      Snails::Logger::Record.new(:info, "app.log", "x", fields: { "1bad" => 1 })
    })
    assert_argument_error(-> {
      Snails::Logger::Record.new(:info, "app.log", "x", fields: { 1 => 1 })
    })
  end

  # A caller cannot overwrite a field name the logger owns.
  def test_record_reserves_context_fields
    assert_argument_error(-> {
      Snails::Logger::Record.new(:info, "app.log", "x", fields: { "event.name" => "other" })
    })
    assert_argument_error(-> {
      Snails::Logger::Record.new(:info, "app.log", "x", fields: { "snails.request_id" => "other" })
    })
    assert_argument_error(-> {
      Snails::Logger::Record.new(:info, "app.log", "x", fields: { "snails.controller" => "other" })
    })
    assert_argument_error(-> {
      Snails::Logger::Record.new(:info, "app.log", "x", fields: { "snails.action" => "other" })
    })
  end

  # Field values allow only simple values OTLP can interpret.
  def test_record_rejects_non_simple_field_values
    assert_argument_error(-> {
      Snails::Logger::Record.new(:info, "app.log", "x", fields: { "a" => [ 1 ] })
    })
    assert_argument_error(-> {
      Snails::Logger::Record.new(:info, "app.log", "x", fields: { "a" => { "b" => 1 } })
    })
    assert_argument_error(-> {
      Snails::Logger::Record.new(:info, "app.log", "x", fields: { "a" => :symbol })
    })
    assert_argument_error(-> {
      Snails::Logger::Record.new(:info, "app.log", "x", fields: { "a" => Time.at(0) })
    })
  end

  # An exception can be exposed as type, message, and stacktrace fields.
  def test_record_exposes_exception_fields
    failure = RuntimeError.new("boom")
    failure.set_backtrace([ "first frame", "second frame" ])
    record = Snails::Logger::Record.new(:error, "job.failed", "failed", exception: failure)

    assert_equal "RuntimeError", record.exception_type
    assert_equal "boom", record.exception_message
    assert_equal "first frame\nsecond frame", record.exception_stacktrace
  end

  # A level call carrying an event builds the local line with record_formatter
  # and passes the record through as is.
  def test_event_call_uses_the_record_formatter
    out = RecordOutput.new
    formatter = RecordingRecordFormatter.new
    logger = new_logger(out)
    logger.progname = "test"
    logger.record_formatter = formatter

    logger.info("GET /up 200", event: "request.completed", fields: { "http.response.status_code" => 200 })

    assert_equal 1, formatter.calls.length
    assert_equal "test", formatter.calls[0]["progname"]
    record = formatter.calls[0]["record"]
    assert_equal "request.completed", record.event
    assert_equal "GET /up 200", record.body
    assert_equal 200, record.fields["http.response.status_code"]
    assert_equal "harness", record.resource["service.name"]
    assert_equal Process.pid, record.resource["process.pid"]
    assert_equal "test", record.resource["deployment.environment.name"]
    assert_equal 1, record.resource["snails.log.schema_version"]
    assert_equal [ "line\n" ], out.lines
  end

  # The level gate also applies to calls carrying an event.
  def test_event_call_respects_the_level
    out = RecordOutput.new
    formatter = RecordingRecordFormatter.new
    logger = new_logger(out)
    logger.level = :warn
    logger.record_formatter = formatter

    logger.info("hidden", event: "request.completed")
    logger.warn("shown", event: "request.completed")

    assert_equal 1, formatter.calls.length
    assert_equal :warn, formatter.calls[0]["record"].severity
  end

  # Even when the level gate blocks logging, invalid arguments do not pass
  # silently.
  def test_event_call_validates_before_the_level
    out = RecordOutput.new
    logger = new_logger(out)
    logger.level = :warn

    message = assert_argument_error(-> {
      logger.info("hidden", event: "Bad Event")
    })
    assert_equal true, message.include?("event expects")
  end

  # exception is passed as a keyword and carried on the record.
  def test_event_call_accepts_an_exception_keyword
    out = RecordOutput.new
    formatter = RecordingRecordFormatter.new
    logger = new_logger(out)
    logger.record_formatter = formatter
    failure = RuntimeError.new("boom")

    logger.error(
      "failed",
      event: "job.failed",
      fields: { "snails.job.status" => "failed" },
      exception: failure
    )

    record = formatter.calls[0]["record"]
    assert_equal "job.failed", record.event
    assert_equal "failed", record.fields["snails.job.status"]
    assert_equal "boom", record.exception_message
  end

  # The default record formatter starts with event.name and uses a timestamp
  # with an offset.
  def test_default_record_formatter_line
    record = Snails::Logger::Record.new(
      :info, "request.completed", "GET /up 200",
      fields: {
        "http.request.method" => "GET",
        "http.response.status_code" => 200,
        "snails.duration_ms" => 0.4
      },
      time: Time.at(0).utc
    )

    line = Snails::Logger::RecordFormatter.new.call(record, "example-service")
    expected = "I, [1970-01-01T00:00:00.000000Z #" + Process.pid.to_s +
               "]  INFO -- example-service: event.name=request.completed " +
               "http.request.method=GET http.response.status_code=200 " +
               "snails.duration_ms=0.4 body=GET /up 200\n"
    assert_equal expected, line
  end

  # Whitespace, quotes, and newlines are escaped so the one-line contract is not
  # broken.
  def test_record_formatter_escapes_values
    failure = RuntimeError.new("boom")
    failure.set_backtrace([ "first frame", "second frame" ])
    record = Snails::Logger::Record.new(
      :error, "job.failed", "first\nsecond",
      fields: { "note" => "a b", "path" => "a\"b" },
      exception: failure,
      time: Time.at(0).utc
    )

    line = Snails::Logger::RecordFormatter.new.call(record, "app")
    assert_equal true, line.include?("note=\"a b\"")
    assert_equal true, line.include?("path=\"a\\\"b\"")
    assert_equal true, line.include?("body=first\\nsecond")
    assert_equal true, line.include?("exception.stacktrace=\"first frame\\nsecond frame\"")
    assert_equal 1, line.split("\n").length
  end

  # A level call with only a string writes the local line through formatter and
  # sends an app.log record to the transport.
  def test_message_only_call_uses_the_formatter_and_delivers
    out = RecordOutput.new
    logger = new_logger(out)
    logger.formatter = MessageOnlyFormatter.new
    transport = RecordCapture.new
    logger.transport = transport

    logger.info("hello")
    logger.flush

    assert_equal [ "hello" ], out.lines
    assert_equal 1, transport.batches.length
    record = transport.batches[0][0]
    assert_equal "app.log", record.event
    assert_equal "hello", record.body
  end

  # Passing fields or exception without event is rejected before the level
  # gate — silently falling back to app.log would erase the caller's intent.
  def test_fields_or_exception_without_event_raise
    out = RecordOutput.new
    logger = new_logger(out)
    logger.level = :fatal

    fields_message = assert_argument_error(-> {
      logger.info("hidden", fields: { "http.response.status_code" => 200 })
    })
    assert_equal true, fields_message.include?("expects event:")

    exception_message = assert_argument_error(-> {
      logger.error("hidden", exception: RuntimeError.new("boom"))
    })
    assert_equal true, exception_message.include?("expects event:")
    assert_equal 0, out.lines.length
  end

  # record was removed from the public surface — an external call raises
  # NoMethodError.
  def test_record_is_no_longer_public
    logger = new_logger(RecordOutput.new)
    blocked = false
    begin
      logger.record(:info, "request.completed", "hidden")
    rescue NoMethodError
      blocked = true
    end

    assert_equal true, blocked
  end

  # Changing the formatters does not change the records the transport receives —
  # rendering and delivery are independent.
  def test_transport_receives_the_same_records_whatever_the_formatters
    out = RecordOutput.new
    logger = new_logger(out)
    transport = RecordCapture.new
    logger.transport = transport
    logger.formatter = MessageOnlyFormatter.new
    logger.record_formatter = FixedRecordFormatter.new

    logger.info("hello")
    logger.info("GET /up 200", event: "request.completed", fields: { "http.response.status_code" => 200 })
    logger.formatter = FixedLineFormatter.new
    logger.record_formatter = RecordingRecordFormatter.new
    logger.info("hello")
    logger.info("GET /up 200", event: "request.completed", fields: { "http.response.status_code" => 200 })
    logger.flush

    assert_equal "hello", out.lines[0]
    assert_equal "fixed record\n", out.lines[1]
    assert_equal "fixed line\n", out.lines[2]
    assert_equal "line\n", out.lines[3]
    assert_equal 1, transport.batches.length
    records = transport.batches[0]
    assert_equal 4, records.length
    assert_equal "app.log", records[0].event
    assert_equal "app.log", records[2].event
    assert_equal "request.completed", records[1].event
    assert_equal "request.completed", records[3].event
    assert_equal 200, records[3].fields["http.response.status_code"]
  end

  # The transport and record_formatter slots reject values that do not answer
  # the contract at assignment time.
  def test_transport_and_record_formatter_validate_their_contract
    logger = Snails::Logger.new
    assert_argument_error(-> { logger.transport = Object.new })
    assert_argument_error(-> { logger.record_formatter = Object.new })

    capture = RecordCapture.new
    logger.transport = capture
    assert_equal capture, logger.transport
    logger.transport = nil
    assert_equal nil, logger.transport
  end

  # A delivery failure does not stop the app; it stays as one local error line.
  def test_transport_failure_is_local_only
    out = RecordOutput.new
    logger = new_logger(out)
    logger.formatter = MessageOnlyFormatter.new
    transport = RaisingTransport.new
    logger.transport = transport

    logger.info("hello")
    logger.flush

    assert_equal 1, transport.calls
    assert_equal "hello", out.lines[0]
    assert_equal true, out.lines[1].include?("dropped 1 record")
    assert_equal true, out.lines[1].include?("transport down")
    assert_equal 2, out.lines.length
  end

  # Writes from multiple threads stay whole line by line — lines do not
  # interleave.
  def test_concurrent_writes_do_not_interleave
    out = RecordOutput.new
    logger = new_logger(out)
    logger.formatter = MessageOnlyFormatter.new

    threads = [
      Thread.new { 20.times { logger.info("a") } },
      Thread.new { 20.times { logger.info("b") } }
    ]
    threads.each { |thread| thread.join }

    assert_equal 40, out.lines.length
    intact = true
    out.lines.each { |line| intact = false unless line == "a" || line == "b" }
    assert_equal true, intact
  end

  # Request and job context are attached to every record as reserved fields.
  def test_context_fields_ride_on_records
    out = RecordOutput.new
    formatter = RecordingRecordFormatter.new
    logger = new_logger(out)
    logger.record_formatter = formatter
    Snails::Logger::Context.begin_request
    Snails::Logger::Context.controller = "ContextController"
    Snails::Logger::Context.action = "show"
    Snails::Logger::Context.begin_job("ContextJob", 42, 1)

    begin
      logger.info("done", event: "job.finished")
    ensure
      Snails::Logger::Context.end_job
    end

    record = formatter.calls[0]["record"]
    assert_equal 8, record.fields["snails.request_id"].length
    assert_equal "ContextController", record.fields["snails.controller"]
    assert_equal "show", record.fields["snails.action"]
    assert_equal "ContextJob", record.fields["snails.job.name"]
    assert_equal 42, record.fields["snails.job.id"]
    assert_equal 1, record.fields["snails.job.attempt"]
  end
end

FixtureRunner.run(LoggerRecordTest, [
  "test_record_exposes_its_values",
  "test_record_exposes_resource_fields",
  "test_record_rejects_an_unknown_severity",
  "test_record_rejects_bad_event_names",
  "test_record_rejects_bad_field_names",
  "test_record_reserves_context_fields",
  "test_record_rejects_non_simple_field_values",
  "test_record_exposes_exception_fields",
  "test_event_call_uses_the_record_formatter",
  "test_event_call_respects_the_level",
  "test_event_call_validates_before_the_level",
  "test_event_call_accepts_an_exception_keyword",
  "test_default_record_formatter_line",
  "test_record_formatter_escapes_values",
  "test_message_only_call_uses_the_formatter_and_delivers",
  "test_fields_or_exception_without_event_raise",
  "test_record_is_no_longer_public",
  "test_transport_receives_the_same_records_whatever_the_formatters",
  "test_transport_and_record_formatter_validate_their_contract",
  "test_transport_failure_is_local_only",
  "test_concurrent_writes_do_not_interleave",
  "test_context_fields_ride_on_records"
])
