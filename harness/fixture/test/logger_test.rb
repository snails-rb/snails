require_relative "test_helper"
require_relative "harness_runner"
require_relative "test_database"

# Snails::Logger (core) — the app-facing logger: the mode-derived default
# level, the level/output/formatter/progname slots, and the request id tag
# the message carries. Stderr formatting is asserted through the default
# formatter with a fixed time, and writes are captured through a recording
# output so the snapshot never bakes in a clock or pid.
class LoggerTest < TestBase
  # Each case starts from the fixture's level with no transport left over
  # from the previous case.
  def setup
    Snails.logger.transport = nil
    Snails.logger.flush
    Snails.logger.level = :info
  end
  # Catches written lines; `flush` belongs to the write path.
  class RecordingOutput
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

  # An output that answers `sync=` and has no `flush` at all: the logger must
  # switch it to sync mode and never flush a line, so calling `flush` here
  # raises NoMethodError and fails the case.
  class SyncOutput
    def initialize
      @lines = []
      @synced = false
    end

    def lines
      @lines
    end

    def synced?
      @synced
    end

    def sync=(on)
      @synced = on
    end

    def write(line)
      @lines << line
    end
  end

  # A transport that parks inside `deliver` until released, so a hand-off can
  # be held open while another thread logs.
  class BlockingTransport
    def initialize
      @lock = Mutex.new
      @started = false
      @release = false
    end

    def started?
      @lock.synchronize { @started }
    end

    def release
      @lock.synchronize { @release = true }
    end

    def deliver(records)
      @lock.synchronize { @started = true }
      released = false
      while !released
        released = @lock.synchronize { @release }
        sleep 0.01 if !released
      end
      nil
    end
  end

  # Records formatter calls without rendering, so assertions read the
  # severity, progname and already-tagged message.
  class RecordingFormatter    def initialize
      @calls = []
    end

    def calls
      @calls
    end

    def call(severity, time, progname, message)
      @calls << { "severity" => severity, "progname" => progname, "message" => message }
      ""
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

  # Outside a request no tag is prepended — the id belongs to a request,
  # not to the logger. This case runs first: the request id is process
  # state once a later case begins a request.
  def test_message_is_untagged_before_a_request
    assert_equal nil, Snails::Logger::Context.request_id

    out = RecordingOutput.new
    fmt = RecordingFormatter.new
    logger = Snails::Logger.new
    logger.output = out
    logger.formatter = fmt
    logger.info("hello")

    assert_equal "hello", fmt.calls[0]["message"]
  end

  # The default line: severity letter, timestamp with the zone offset, pid,
  # right-aligned level, progname and message. The pid is read from the
  # running process, so no volatile value reaches the snapshot.
  def test_default_formatter_line
    fmt = Snails::Logger::Formatter.new
    line = fmt.call("INFO", Time.at(0).utc, "app", "hello")
    assert_equal "I, [1970-01-01T00:00:00.000000Z #" + Process.pid.to_s + "]  INFO -- app: hello\n", line
  end

  # Both local lines name an instant one way: the app string call and the
  # framework event carry the same timestamp while the zone says Seoul, so a
  # mixed log stream stays readable. The zone is restored for the plain
  # all-files-in-one-process runner path.
  def test_both_formatters_spell_the_timestamp_alike
    Snails.time_zone = "Seoul"
    now = Time.at(0).utc

    default_line = Snails::Logger::Formatter.new.call("INFO", now, "app", "hello")
    record_line = Snails::Logger::RecordFormatter.new.call(
      Snails::Logger::Record.new(:info, "app.log", "hello", time: now), "app"
    )
    Snails.time_zone = "UTC"

    stamp = "[1970-01-01T09:00:00.000000+09:00 #"
    assert_equal true, default_line.include?(stamp)
    assert_equal true, record_line.include?(stamp)
  end

  # A transport stuck in the hand-off does not block logging from other
  # threads. Expectation: the second line is recorded before the transport is
  # released, and the first hand-off finishes after the release. If the local
  # render lock wrapped the hand-off, this case would stall first.
  def test_a_blocked_transport_does_not_hold_other_threads_logging
    out = RecordingOutput.new
    Snails.logger.output = out
    transport = BlockingTransport.new
    Snails.logger.transport = transport

    first = Thread.new do
      Snails.logger.info("blocked")
      Snails.logger.flush
    end
    waiting = true
    while waiting
      waiting = !transport.started?
      sleep 0.01 if waiting
    end

    done = [ false ]
    done_lock = Mutex.new
    second = Thread.new do
      Snails.logger.info("concurrent")
      done_lock.synchronize { done[0] = true }
    end
    waited = 0.0
    while waited < 2.0
      break if done_lock.synchronize { done[0] }
      sleep 0.02
      waited = waited + 0.02
    end
    transport.release
    second.join
    first.join

    assert_equal true, done_lock.synchronize { done[0] }
    assert_equal 2, out.lines.length
  end

  # Without an explicit level the mode decides: development is verbose,
  # every other mode writes info and above.
  def test_default_level_follows_the_mode
    Snails.env = "development"
    assert_equal :debug, Snails::Logger.new.level

    Snails.env = "staging"
    assert_equal :info, Snails::Logger.new.level

    Snails.env = ENV["SNAILS_ENV"]
  end

  # An explicit level wins over the mode and gates every write at or
  # above it; the predicates answer the same gate.
  def test_explicit_level_gates_writes_and_predicates
    out = RecordingOutput.new
    fmt = RecordingFormatter.new
    logger = Snails::Logger.new
    logger.output = out
    logger.formatter = fmt
    logger.level = :warn

    assert_equal false, logger.debug?
    assert_equal false, logger.info?
    assert_equal true, logger.warn?
    assert_equal true, logger.fatal?

    logger.info("hidden")
    logger.warn("shown")
    logger.error("shown too")

    assert_equal 2, fmt.calls.length
    assert_equal "WARN", fmt.calls[0]["severity"]
    assert_equal "shown", fmt.calls[0]["message"]
    assert_equal "ERROR", fmt.calls[1]["severity"]
  end

  # A line reaches a stream by its own write: the first write through an
  # output that answers `sync=` turns sync on, and no line calls `flush` (this
  # output has none, so a flush would raise).
  def test_output_is_switched_to_sync_and_never_flushed
    out = SyncOutput.new
    logger = Snails::Logger.new
    logger.output = out

    logger.info("hello")
    logger.info("again")

    assert_equal true, out.synced?
    assert_equal 2, out.lines.length
  end

  # A typo in any slot stops at configuration time — a logger that
  # silently writes nowhere is the failure this rejects.
  def test_configuration_rejects_bad_values
    logger = Snails::Logger.new

    level_message = assert_argument_error(-> { logger.level = :verbose })
    assert_equal true, level_message.include?(":debug, :info, :warn, :error, :fatal")

    output_message = assert_argument_error(-> { logger.output = "log/app.log" })
    assert_equal true, output_message.include?("an IO")

    formatter_message = assert_argument_error(-> { logger.formatter = "not a formatter" })
    assert_equal true, formatter_message.include?("answering call")
  end

  # The app environment file ran before the cases and its slots are the
  # ones the process writes through.
  def test_environment_file_configured_the_shared_logger
    assert_equal true, Snails.logger.equal?(Snails.logger)
    assert_equal :info, Snails.logger.level
    assert_equal "fixture", Snails.logger.progname
  end

  # While a request runs, every line carries its id as a key=value field,
  # so a replacement formatter receives the tag too and the line stays
  # parseable. The id stays set after the request — the request record and
  # any app line after the action read it.
  def test_request_id_tags_the_message
    id = Snails::Logger::Context.begin_request
    assert_equal 8, id.length
    assert_equal id, Snails::Logger::Context.request_id

    out = RecordingOutput.new
    fmt = RecordingFormatter.new
    logger = Snails::Logger.new
    logger.output = out
    logger.formatter = fmt
    logger.info("hello")

    assert_equal "request_id=" + id + " hello", fmt.calls[0]["message"]
  end

  # A successful request writes exactly one info record: method, path,
  # status, numeric duration, the matched controller/action, and the id.
  def test_dispatch_writes_one_completed_record
    TestDatabase.configure!("logger_dispatch")

    capture = RecordCapture.new
    Snails.logger.output = CapturedLog.new
    Snails.logger.transport = capture

    req = Tep::Request.new
    req.verb = "GET"
    req.path = "/up"
    req.raw_path = "/up"
    req.remote_host = +"127.0.0.1"
    res = Tep::Response.new
    Tep::APP.dispatch(req, res)

    assert_equal 200, res.status
    Snails.logger.flush

    assert_equal 1, capture.records.length
    record = capture.records[0]
    assert_equal "request.completed", record.event
    assert_equal :info, record.severity
    assert_equal "GET", record.fields["http.request.method"]
    assert_equal "/up", record.fields["url.path"]
    assert_equal 200, record.fields["http.response.status_code"]
    assert_equal true, record.fields["snails.duration_ms"] >= 0.0
    assert_equal 0.0, record.fields["snails.db_ms"]
    assert_equal "Snails::HealthController", record.fields["snails.controller"]
    assert_equal "show", record.fields["snails.action"]
    assert_equal "json", record.fields["snails.format"]
    assert_equal Snails::Logger::Context.request_id, record.fields["snails.request_id"]
  end

  # A failed request writes exactly one error record; the exception travels
  # on that record instead of a second stack line.
  def test_dispatch_writes_one_failed_record
    TestDatabase.configure!("logger_dispatch")

    capture = RecordCapture.new
    Snails.logger.output = CapturedLog.new
    Snails.logger.transport = capture

    req = Tep::Request.new
    req.verb = "GET"
    req.path = "/boom"
    req.raw_path = "/boom"
    req.remote_host = +"127.0.0.1"
    res = Tep::Response.new
    begin
      Tep::APP.dispatch(req, res)
    rescue StandardError
    end

    Snails.logger.flush

    assert_equal 1, capture.records.length
    record = capture.records[0]
    assert_equal "request.failed", record.event
    assert_equal :error, record.severity
    assert_equal "GET", record.fields["http.request.method"]
    assert_equal "/boom", record.fields["url.path"]
    assert_equal 500, record.fields["http.response.status_code"]
    assert_equal 0.0, record.fields["snails.db_ms"]
    assert_equal "HarnessBoomController", record.fields["snails.controller"]
    assert_equal "show", record.fields["snails.action"]
    assert_equal "RuntimeError", record.exception_type
    assert_equal "boom", record.exception_message
  end

  # A controller that returns a 5xx without raising is still one error
  # record; the exception is nil.
  def test_dispatch_writes_one_failed_record_for_a_returned_500
    TestDatabase.configure!("logger_dispatch")

    capture = RecordCapture.new
    Snails.logger.output = CapturedLog.new
    Snails.logger.transport = capture

    req = Tep::Request.new
    req.verb = "GET"
    req.path = "/server-error"
    req.raw_path = "/server-error"
    req.remote_host = +"127.0.0.1"
    res = Tep::Response.new
    Tep::APP.dispatch(req, res)

    assert_equal 500, res.status
    Snails.logger.flush

    assert_equal 1, capture.records.length
    record = capture.records[0]
    assert_equal "request.failed", record.event
    assert_equal :error, record.severity
    assert_equal 500, record.fields["http.response.status_code"]
    assert_equal nil, record.exception
  end

  # A ScriptError (NotImplementedError) is a unit failure, not process
  # control: the request leaves one error record and the next request can
  # still be served.
  def test_dispatch_treats_a_script_error_as_a_failed_record
    TestDatabase.configure!("logger_dispatch")

    capture = RecordCapture.new
    Snails.logger.output = CapturedLog.new
    Snails.logger.transport = capture

    req = Tep::Request.new
    req.verb = "GET"
    req.path = "/not-implemented"
    req.raw_path = "/not-implemented"
    req.remote_host = +"127.0.0.1"
    res = Tep::Response.new
    begin
      Tep::APP.dispatch(req, res)
    rescue NotImplementedError
    end

    Snails.logger.flush

    assert_equal 1, capture.records.length
    record = capture.records[0]
    assert_equal "request.failed", record.event
    assert_equal :error, record.severity
    assert_equal 500, record.fields["http.response.status_code"]
    assert_equal "NotImplementedError", record.exception_type
    assert_equal "not implemented", record.exception_message
  end
end

FixtureRunner.run(LoggerTest, [
  "test_message_is_untagged_before_a_request",
  "test_default_formatter_line",
  "test_default_level_follows_the_mode",
  "test_explicit_level_gates_writes_and_predicates",
  "test_output_is_switched_to_sync_and_never_flushed",
  "test_configuration_rejects_bad_values",
  "test_environment_file_configured_the_shared_logger",
  "test_request_id_tags_the_message",
  "test_dispatch_writes_one_completed_record",
  "test_dispatch_writes_one_failed_record",
  "test_dispatch_writes_one_failed_record_for_a_returned_500",
  "test_dispatch_treats_a_script_error_as_a_failed_record",
  "test_both_formatters_spell_the_timestamp_alike",
  "test_a_blocked_transport_does_not_hold_other_threads_logging"
])
