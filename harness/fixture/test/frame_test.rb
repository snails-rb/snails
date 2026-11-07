require_relative "test_helper"
require_relative "harness_runner"

# Tep::WebSocket::Frame — the client-frame parser and the private opcode
# classifiers behind it.
class FrameTest < TestBase
  def assert_equal(expected, actual)
    raise("expected #{expected.inspect}, got #{actual.inspect}") unless expected == actual
  end

  # A masked client text frame parses through the public entry.
  def test_parse_masked_text_frame
    mask = [1, 2, 3, 4]
    payload = "hi"
    bytes = [0x81, 0x80 | payload.bytesize]
    bytes.concat(mask)
    i = 0
    while i < payload.bytesize
      bytes << (payload.getbyte(i) ^ mask[i & 3])
      i += 1
    end
    s = bytes.pack("C*")
    result = Tep::WebSocket::Frame.parse_from_buf(s, 0, s.bytesize)
    assert_equal "ok", result.outcome
    assert_equal "hi", result.frame.payload
  end

  # A reserved opcode is a protocol violation through the same entry.
  def test_reserved_opcode_closes
    s = [0x83, 0x80, 0, 0, 0, 0].pack("C*")
    result = Tep::WebSocket::Frame.parse_from_buf(s, 0, s.bytesize)
    assert_equal "close", result.outcome
    assert_equal Tep::WebSocket::CLOSE_PROTOCOL_ERROR, result.close_code
  end

  # A fragmented control frame is a protocol violation.
  def test_fragmented_control_frame_closes
    s = [0x09, 0x80, 0, 0, 0, 0].pack("C*")
    result = Tep::WebSocket::Frame.parse_from_buf(s, 0, s.bytesize)
    assert_equal "close", result.outcome
  end

  # The opcode classifiers sit behind `parse_from_buf`; an app calling one
  # from outside is refused.
  def test_opcode_helpers_are_private
    begin
      Tep::WebSocket::Frame.reserved_opcode?(1)
    rescue NoMethodError
      return
    end
    raise "expected Tep::WebSocket::Frame.reserved_opcode? to be private"
  end
end

FixtureRunner.run(FrameTest, [
  "test_parse_masked_text_frame",
  "test_reserved_opcode_closes",
  "test_fragmented_control_frame_closes",
  "test_opcode_helpers_are_private"
])
