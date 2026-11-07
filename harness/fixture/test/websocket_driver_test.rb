require_relative "test_helper"
require_relative "harness_runner"

# Tep::WebSocket::Driver — the outbound frame writer an app reaches through
# `text`, `binary`, `ping`, `pong`, and `close`.
class WebSocketDriverTest < TestBase
  def assert_equal(expected, actual)
    raise("expected #{expected.inspect}, got #{actual.inspect}") unless expected == actual
  end

  # `text` reaches the private frame writer. The fd is invalid, so the write
  # itself is refused — the public entry still returns its result rather than
  # raising.
  def test_text_reaches_the_frame_writer
    driver = Tep::WebSocket::Driver.new(-1)
    assert_equal(-1, driver.text("hi"))
  end

  # `close` reaches the private close-payload encoder and then the frame
  # writer, with the same refused-fd result.
  def test_close_reaches_the_close_encoder
    driver = Tep::WebSocket::Driver.new(-1)
    assert_equal(-1, driver.close(0, ""))
  end
end

FixtureRunner.run(WebSocketDriverTest, [
  "test_text_reaches_the_frame_writer",
  "test_close_reaches_the_close_encoder"
])
