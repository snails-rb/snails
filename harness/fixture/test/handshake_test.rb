require_relative "test_helper"
require_relative "harness_runner"

# Tep::WebSocket::Handshake — the server-side upgrade check and response, and
# the private header helpers behind them.
class HandshakeTest < TestBase
  def assert_equal(expected, actual)
    raise("expected #{expected.inspect}, got #{actual.inspect}") unless expected == actual
  end

  # The response is a 101 head with the accept key, and it echoes a chosen
  # subprotocol only when one is present.
  def test_build_response
    head = Tep::WebSocket::Handshake.build_response("abc", "")
    assert_equal true, head.start_with?("HTTP/1.1 101 Switching Protocols\r\n")
    assert_equal true, head.include?("Sec-WebSocket-Accept: abc\r\n")
    assert_equal false, head.include?("Sec-WebSocket-Protocol:")
    with_protocol = Tep::WebSocket::Handshake.build_response("abc", "chat")
    assert_equal true, with_protocol.include?("Sec-WebSocket-Protocol: chat\r\n")
  end

  # `check` rejects a non-GET request before it reads the handshake key.
  def test_check_rejects_non_get
    req = Tep::Request.new
    req.verb = "POST"
    result = Tep::WebSocket::Handshake.check(req)
    assert_equal false, result.valid
    assert_equal "bad verb", result.reason
  end

  # The header helpers sit behind check/build_response; an app calling one
  # from outside is refused.
  def test_header_helpers_are_private
    begin
      Tep::WebSocket::Handshake.icontains("a", "a")
    rescue NoMethodError
      return
    end
    raise "expected Tep::WebSocket::Handshake.icontains to be private"
  end
end

FixtureRunner.run(HandshakeTest, [
  "test_build_response",
  "test_check_rejects_non_get",
  "test_header_helpers_are_private"
])
