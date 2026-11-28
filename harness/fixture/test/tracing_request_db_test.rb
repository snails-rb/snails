require_relative "test_helper"
require_relative "harness_runner"
require_relative "test_database"

# The request and DB auto spans: the request span parents the DB spans, route
# names stay low-cardinality, status follows HTTP/exception, and DB summaries
# never carry a bound value.
TestDatabase.configure!("tracing_request_db")

class TracingRequestDbTest < TestBase
  TRACE_ID = "0af7651916cd43dd8448eb211c80319c"
  PARENT_SPAN_ID = "b7ad6b7169203331"

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
    Snails.tracer.db_query_text = false
    TestDatabase.drop_tables!("trace_items")
    TestDatabase.exec("CREATE TABLE trace_items (id INTEGER PRIMARY KEY, name TEXT NOT NULL)")
    TestDatabase.exec("INSERT INTO trace_items (id, name) VALUES (1, 'alpha')")
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

  def dispatch(verb, path, headers = {})
    req = Tep::Request.new
    req.verb = verb
    req.path = path
    req.raw_path = path
    req.remote_host = +"127.0.0.1"
    headers.each { |name, value| req.req_headers[name] = value }
    res = Tep::Response.new
    Tep::APP.dispatch(req, res)
    res
  end

  def find_span(spans, name)
    i = 0
    while i < spans.length
      return spans[i] if spans[i].name == name
      i += 1
    end
    nil
  end

  def find_span_with_attribute(spans, key, value)
    i = 0
    while i < spans.length
      attributes = spans[i].attributes
      return spans[i] if attributes[key] == value
      i += 1
    end
    nil
  end

  def backend_name
    TestDatabase.pg? ? "postgresql" : "sqlite"
  end

  # The request span is the server root; the DB span is its client child and
  # carries the statement summary, not the SQL values.
  def test_request_span_parents_the_db_span
    capture = enable_tracing
    dispatch("GET", "/db-probe")
    spans = flush_spans(capture)

    request = find_span(spans, "GET /db-probe")
    db = find_span(spans, "SELECT")
    assert_equal false, request.nil?
    assert_equal false, db.nil?
    assert_equal :server, request.kind
    assert_equal :client, db.kind
    assert_equal request.trace_id, db.trace_id
    assert_equal request.span_id, db.parent_span_id
    assert_equal nil, request.parent_span_id
    assert_equal :ok, request.status
    assert_equal :ok, db.status

    attributes = request.attributes
    assert_equal "GET", attributes["http.request.method"]
    assert_equal "/db-probe", attributes["url.path"]
    assert_equal "/db-probe", attributes["http.route"]
    assert_equal 200, attributes["http.response.status_code"]
    assert_equal "HarnessDbProbeController", attributes["snails.controller"]
    assert_equal "show", attributes["snails.action"]
    assert_equal Snails::Logger::Context.request_id, attributes["snails.request_id"]

    db_attributes = db.attributes
    assert_equal backend_name, db_attributes["db.system.name"]
    assert_equal "SELECT", db_attributes["db.operation.name"]
    assert_equal "SELECT", db_attributes["db.query.summary"]
    assert_equal 1, db_attributes["db.response.returned_rows"]
    assert_equal nil, db_attributes["db.query.text"]
    assert_equal nil, db_attributes["snails.db.cache_hit"]
  end

  # A path capture stays a route pattern in the span name; the concrete path
  # lives in `url.path`.
  def test_request_span_uses_the_route_pattern
    capture = enable_tracing
    dispatch("GET", "/trace-probe/42")
    spans = flush_spans(capture)

    request = find_span(spans, "GET /trace-probe/:id")
    assert_equal false, request.nil?
    attributes = request.attributes
    assert_equal "/trace-probe/:id", attributes["http.route"]
    assert_equal "/trace-probe/42", attributes["url.path"]
    assert_equal :ok, request.status
  end

  # A route miss has no route attribute and keeps the method-only name;
  # 4xx stays unset rather than error.
  def test_request_span_for_a_route_miss
    capture = enable_tracing
    dispatch("GET", "/nope")
    spans = flush_spans(capture)

    request = find_span(spans, "GET")
    assert_equal false, request.nil?
    attributes = request.attributes
    assert_equal nil, attributes["http.route"]
    assert_equal 404, attributes["http.response.status_code"]
    assert_equal :unset, request.status
  end

  # A returned 5xx is an error status without an exception event.
  def test_request_span_marks_a_server_error
    capture = enable_tracing
    dispatch("GET", "/server-error")
    spans = flush_spans(capture)

    request = find_span(spans, "GET /server-error")
    assert_equal false, request.nil?
    assert_equal :error, request.status
    assert_equal 500, request.attributes["http.response.status_code"]
    assert_equal 0, request.events.length
  end

  # An action exception becomes an error status, an exception event, and a
  # 500 status code, then reaches the server.
  def test_request_span_records_an_exception
    capture = enable_tracing
    begin
      dispatch("GET", "/boom")
    rescue StandardError
      nil
    end
    spans = flush_spans(capture)

    request = find_span(spans, "GET /boom")
    assert_equal false, request.nil?
    assert_equal :error, request.status
    assert_equal 500, request.attributes["http.response.status_code"]
    assert_equal 1, request.events.length
    assert_equal "exception", request.events[0]["name"]
    assert_equal "RuntimeError", request.events[0]["attributes"]["exception.type"]
    assert_equal "boom", request.events[0]["attributes"]["exception.message"]
  end

  # A valid inbound traceparent becomes the request span's trace and parent;
  # a malformed one is ignored and a new trace starts.
  def test_request_span_continues_an_inbound_trace
    capture = enable_tracing
    dispatch("GET", "/up", {
      "traceparent" => "00-" + TRACE_ID + "-" + PARENT_SPAN_ID + "-01",
      "tracestate" => "vendor=value"
    })
    spans = flush_spans(capture)

    request = find_span(spans, "GET /up")
    assert_equal false, request.nil?
    assert_equal TRACE_ID, request.trace_id
    assert_equal PARENT_SPAN_ID, request.parent_span_id
    assert_equal :ok, request.status

    capture = enable_tracing
    dispatch("GET", "/up", { "traceparent" => "00-not-hex-" + PARENT_SPAN_ID + "-01" })
    spans = flush_spans(capture)
    request = find_span(spans, "GET /up")
    assert_equal false, request.nil?
    assert_equal false, request.trace_id == TRACE_ID
    assert_equal nil, request.parent_span_id
  end

  # An inbound sampled=false trace records no request span.
  def test_request_span_skips_an_unsampled_inbound_trace
    capture = enable_tracing
    dispatch("GET", "/up", {
      "traceparent" => "00-" + TRACE_ID + "-" + PARENT_SPAN_ID + "-00"
    })
    spans = flush_spans(capture)
    assert_equal 0, spans.length
  end

  # The second identical read in one lease is a cache hit span with the
  # cache flag and the cached row count.
  def test_db_cache_hit_is_a_span
    capture = enable_tracing
    Sqlx::Database.with_connection do
      Sqlx::Database.exec_read("SELECT name FROM trace_items WHERE id = ?", [1])
      Sqlx::Database.exec_read("SELECT name FROM trace_items WHERE id = ?", [1])
    end
    spans = flush_spans(capture)

    first = find_span(spans, "SELECT trace_items")
    assert_equal false, first.nil?
    second = find_span_with_attribute(spans, "snails.db.cache_hit", true)
    assert_equal false, second.nil?
    assert_equal false, first.equal?(second)
    assert_equal "SELECT trace_items", second.attributes["db.query.summary"]
    assert_equal 1, second.attributes["db.response.returned_rows"]
  end

  # A raw statement is summarized without its values; opt-in text covers only
  # the caller's parameterized SQL.
  def test_db_spans_keep_values_out_of_the_summary
    capture = enable_tracing
    Sqlx::Database.with_connection do
      Sqlx::Database.exec("INSERT INTO trace_items (id, name) VALUES (2, 'beta')")
    end
    spans = flush_spans(capture)

    insert = find_span(spans, "INSERT trace_items")
    assert_equal false, insert.nil?
    assert_equal "INSERT trace_items", insert.attributes["db.query.summary"]
    assert_equal nil, insert.attributes["db.query.text"]
    summary = insert.attributes["db.query.summary"]
    assert_equal false, summary.include?("beta")
  end

  # Opt-in `db.query.text` carries the parameterized statement and no bound
  # value; a raw statement still has no text.
  def test_db_query_text_is_opt_in_and_parameterized
    Snails.tracer.db_query_text = true
    capture = enable_tracing
    Sqlx::Database.with_connection do
      Sqlx::Database.exec_read("SELECT ? AS value", [7])
      Sqlx::Database.exec("SELECT 1 AS one")
    end
    spans = flush_spans(capture)

    text_span = find_span_with_attribute(spans, "db.query.text", "SELECT ? AS value")
    assert_equal false, text_span.nil?
    assert_equal false, text_span.attributes["db.query.text"].include?("7")

    raw_span = nil
    i = 0
    while i < spans.length
      attributes = spans[i].attributes
      if attributes["db.operation.name"] == "SELECT" && attributes["db.query.text"].nil?
        raw_span = spans[i]
      end
      i += 1
    end
    assert_equal false, raw_span.nil?
  end

  # A failed statement records an error status and exception event on its DB
  # span.
  def test_db_span_records_a_statement_failure
    capture = enable_tracing
    begin
      Sqlx::Database.with_connection { Sqlx::Database.exec("THIS IS NOT SQL") }
    rescue StandardError
      nil
    end
    spans = flush_spans(capture)

    failed = find_span(spans, "UNKNOWN")
    assert_equal false, failed.nil?
    assert_equal :error, failed.status
    assert_equal 1, failed.events.length
    assert_equal "exception", failed.events[0]["name"]
    assert_equal "RuntimeError", failed.events[0]["attributes"]["exception.type"]
  end
end

FixtureRunner.run(TracingRequestDbTest, [
  "test_request_span_parents_the_db_span",
  "test_request_span_uses_the_route_pattern",
  "test_request_span_for_a_route_miss",
  "test_request_span_marks_a_server_error",
  "test_request_span_records_an_exception",
  "test_request_span_continues_an_inbound_trace",
  "test_request_span_skips_an_unsampled_inbound_trace",
  "test_db_cache_hit_is_a_span",
  "test_db_spans_keep_values_out_of_the_summary",
  "test_db_query_text_is_opt_in_and_parameterized",
  "test_db_span_records_a_statement_failure"
])
