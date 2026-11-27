require_relative "test_helper"
require_relative "harness_runner"
require_relative "../snails-core/snails/harness"

# The harness request surface — `options` sends a real OPTIONS over the wire,
# and an unsupported verb or an OPTIONS body is refused at the entry instead
# of being sent as another verb. The live case drives the fixture's CORS
# policy, so the preflight answer is the dispatcher's, not a stub.
class HarnessRequestTest < TestBase
  def assert_equal(expected, actual)
    raise("expected #{expected.inspect}, got #{actual.inspect}") unless expected == actual
  end

  # A preflight through the harness helper reaches the fixture's dispatcher
  # and comes back as the policy's 204 with the allow headers.
  def test_options_helper_sends_a_preflight
    port = 20000 + (Tep::Sock.sphttp_getpid % 20000)
    listener = -1
    attempts = 0
    while listener < 0 && attempts < 10
      listener = Tep::Sock.sphttp_listen(port, 0)
      port += 1 if listener < 0
      attempts += 1
    end
    raise("no free port for the preflight") if listener < 0

    server = Thread.new(listener) do |socket|
      client = Tep::Sock.sphttp_accept(socket)
      Tep::Server::Threaded.new.send(:handle_connection, client)
    end

    probe = Snails::Harness::IntegrationTest.new("http://127.0.0.1:" + port.to_s)
    begin
      probe.options("/current-probe", headers: {
        "Connection" => "close",
        "Origin" => "https://app.example.com",
        "Access-Control-Request-Method" => "GET",
        "Access-Control-Request-Headers" => "Content-Type"
      })
    ensure
      Tep::Sock.sphttp_close(listener)
      server.join
    end

    assert_equal 204, probe.response.status
    assert_equal "https://app.example.com", probe.response.headers["Access-Control-Allow-Origin"]
    assert_equal "GET, POST", probe.response.headers["Access-Control-Allow-Methods"]
  end

  # A verb outside the five is refused before a request goes out. The old
  # builder's else branch sent DELETE, which would make a case assert the
  # wrong response.
  def test_unsupported_verb_is_refused
    begin
      Snails::Harness.request(:patch, "/", "http://127.0.0.1:1", nil, nil, nil)
    rescue ArgumentError
      return
    end
    raise("expected ArgumentError for an unsupported verb")
  end

  # A preflight carries no body, so params on :options are refused instead of
  # being attached to the request.
  def test_options_refuses_a_body
    begin
      Snails::Harness.request(:options, "/", "http://127.0.0.1:1", { "x" => "1" }, nil, nil)
    rescue ArgumentError
      return
    end
    raise("expected ArgumentError for an OPTIONS body")
  end
end

FixtureRunner.run(HarnessRequestTest, [
  "test_options_helper_sends_a_preflight",
  "test_unsupported_verb_is_refused",
  "test_options_refuses_a_body"
])
