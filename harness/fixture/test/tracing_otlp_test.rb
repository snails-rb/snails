require_relative "test_helper"
require_relative "harness_runner"

# The OTLP traces encoder and the shared HTTP transport paths. The golden file
# is the wire reference for resource/scope/span fields, enum integers, hex ids,
# and nanosecond timestamps.
class TracingOtlpTest < TestBase
  GOLDEN = "tracing/otlp_traces_golden.json"
  TRACE_ID = "0af7651916cd43dd8448eb211c80319c"
  ROOT_SPAN_ID = "b7ad6b7169203331"
  CHILD_SPAN_ID = "00f067aa0ba902b7"

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

  def resource
    {
      "service.name" => "example-service",
      "service.version" => "v1.2.3",
      "host.name" => "example-host",
      "process.pid" => 1234,
      "deployment.environment.name" => "production",
      "snails.version" => "v0.20.0",
      "snails.rev" => "0123456789abcdef0123456789abcdef01234567",
      "snails.trace.schema_version" => 1
    }
  end

  def root_span
    span = Snails::Tracer::Span.new(
      name: "GET /posts/:id",
      trace_id: TRACE_ID,
      span_id: ROOT_SPAN_ID,
      parent_span_id: nil,
      kind: :server,
      start_time: Time.at(1760000000, 123456).utc,
      attributes: {
        "http.request.method" => "GET",
        "url.path" => "/posts/42",
        "http.route" => "/posts/:id",
        "http.response.status_code" => 200,
        "custom.ratio" => 1.5,
        "custom.flag" => true,
        "snails.request_id" => "ab12cd34"
      }
    )
    span.add_event("payment.attempt", attributes: { "attempt" => 1 }, timestamp: Time.at(1760000000, 124000).utc)
    span.set_status(:ok)
    span.finish(end_time: Time.at(1760000000, 129999).utc)
    span
  end

  def child_span
    span = Snails::Tracer::Span.new(
      name: "SELECT posts",
      trace_id: TRACE_ID,
      span_id: CHILD_SPAN_ID,
      parent_span_id: ROOT_SPAN_ID,
      kind: :client,
      start_time: Time.at(1760000000, 123789).utc,
      attributes: {
        "db.system.name" => "sqlite",
        "db.operation.name" => "SELECT",
        "db.collection.name" => "posts",
        "db.query.summary" => "SELECT posts",
        "db.response.returned_rows" => 1
      }
    )
    span.set_status(:error, message: "db failed")
    span.finish(end_time: Time.at(1760000000, 126000).utc)
    span
  end

  # The encoder matches the golden fixture: resource attributes, scope, span
  # fields, enum integers, status, event, and nanosecond times.
  def test_encoder_matches_the_golden_fixture
    encoded = Snails::Tracer::OTLPEncoder.encode([root_span, child_span], resource, "v0.20.0")
    expected = JSON.parse(File.read(GOLDEN))
    assert_equal expected, encoded
  end

  # The traces transport validates endpoint/token at boot and appends the
  # signal path itself.
  def test_tracer_transport_validates_and_uses_the_traces_path
    message = assert_argument_error(-> {
      Snails::Tracer::OTLPTransport.new(endpoint: "", token: "token")
    })
    assert_equal true, message.include?("endpoint")

    message = assert_argument_error(-> {
      Snails::Tracer::OTLPTransport.new(endpoint: "https://collector.example.com", token: "")
    })
    assert_equal true, message.include?("token")

    transport = Snails::Tracer::OTLPTransport.new(
      endpoint: "https://collector.example.com/otlp",
      token: "token"
    )
    assert_equal "https://collector.example.com/otlp/v1/traces", transport.url.to_s
  end

  # Logs use the same helper and their own path, not a copied HTTP stack.
  def test_logs_transport_uses_the_shared_helper_and_logs_path
    transport = Snails::Logger::OTLPTransport.new(
      endpoint: "https://collector.example.com/otlp/",
      token: "token"
    )
    assert_equal "https://collector.example.com/otlp/v1/logs", transport.url.to_s
  end
end

FixtureRunner.run(TracingOtlpTest, [
  "test_encoder_matches_the_golden_fixture",
  "test_tracer_transport_validates_and_uses_the_traces_path",
  "test_logs_transport_uses_the_shared_helper_and_logs_path"
])
