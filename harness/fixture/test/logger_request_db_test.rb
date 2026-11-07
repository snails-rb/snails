require_relative "test_helper"
require_relative "harness_runner"
require_relative "test_database"

# The request record reports the time spent inside the DB adapter as
# `snails.db_ms`. The field is measured, not inferred: a request that runs a
# real statement must report a value above zero, while a request that never
# reaches the database reports zero.
class LoggerRequestDbTest < TestBase
  def setup
    Snails.logger.transport = nil
    Snails.logger.flush
    Snails.logger.level = :info
  end

  def assert_equal(expected, actual)
    raise("expected #{expected.inspect}, got #{actual.inspect}") unless expected == actual
  end

  def dispatch_get(path)
    req = Tep::Request.new
    req.verb = "GET"
    req.path = path
    req.raw_path = path
    req.remote_host = +"127.0.0.1"
    Tep::APP.dispatch(req, Tep::Response.new)
  end

  # A real statement inside the request raises the accumulated DB time above
  # zero, and the completed record carries it.
  def test_request_db_ms_is_nonzero_for_a_real_query
    TestDatabase.configure!("logger_request_db")

    capture = RecordCapture.new
    Snails.logger.output = CapturedLog.new
    Snails.logger.transport = capture

    dispatch_get("/db-probe")
    Snails.logger.flush

    assert_equal 1, capture.records.length
    record = capture.records[0]
    assert_equal "request.completed", record.event
    assert_equal true, record.fields["snails.db_ms"] > 0.0
  end

  # A request that never touches the DB reports a measured zero, not an
  # omitted field.
  def test_request_db_ms_is_zero_without_a_query
    TestDatabase.configure!("logger_request_db")

    capture = RecordCapture.new
    Snails.logger.output = CapturedLog.new
    Snails.logger.transport = capture

    dispatch_get("/up")
    Snails.logger.flush

    assert_equal 1, capture.records.length
    record = capture.records[0]
    assert_equal "request.completed", record.event
    assert_equal 0.0, record.fields["snails.db_ms"]
  end

  # The accumulator belongs to one request: the next request starts from zero
  # even when the previous one ran queries.
  def test_context_resets_db_time_per_request
    Snails::Logger::Context.begin_request
    Snails::Logger::Context.add_db_us(123)
    assert_equal 123, Snails::Logger::Context.db_us

    Snails::Logger::Context.begin_request
    assert_equal 0, Snails::Logger::Context.db_us
  end
end

FixtureRunner.run(LoggerRequestDbTest, [
  "test_request_db_ms_is_nonzero_for_a_real_query",
  "test_request_db_ms_is_zero_without_a_query",
  "test_context_resets_db_time_per_request"
])
