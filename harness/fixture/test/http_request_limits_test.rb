require_relative "test_helper"
require_relative "harness_runner"

# HTTP request framing limits: the parser refuses an ambiguous framing header,
# and the body drains refuse an oversized or stalled body. The socket cases run
# the threaded server's real handle_connection on one end of a loopback pair,
# so the parser and the response mapping are exercised together.
class HttpRequestLimitsTest < TestBase
  # Stands in for a connection whose peer sent headers but no body bytes: the
  # timed wait reports no readiness.
  class NeverReadyIo
    def wait_readable(seconds)
      nil
    end
  end

  def assert_equal(expected, actual)
    raise("expected #{expected.inspect}, got #{actual.inspect}") unless expected == actual
  end

  # The threaded server's connection loop on the accepted end of the pair.
  def serve_threaded(fd)
    Tep::Server::Threaded.new.send(:handle_connection, fd)
  end

  # One request/response exchange: the request bytes go in on the client end,
  # the server half runs on the accepted end and closes it, and the response
  # bytes come back through to that close.
  def exchange(request)
    port = 20000 + (Tep::Sock.sphttp_getpid % 20000)
    listener = -1
    attempts = 0
    while listener < 0 && attempts < 10
      listener = Tep::Sock.sphttp_listen(port, 0)
      port += 1 if listener < 0
      attempts += 1
    end
    raise("no free port for the exchange") if listener < 0

    client_fd = Tep::Sock.sphttp_connect("127.0.0.1", port)
    raise("connect failed with fd " + client_fd.to_s) if client_fd < 0
    accepted_fd = Tep::Sock.sphttp_accept(listener)
    raise("accept failed with fd " + accepted_fd.to_s) if accepted_fd < 0

    Tep::Sock.sphttp_write_str(client_fd, request) unless request.nil?
    yield accepted_fd

    bytes = read_to_eof(client_fd)
    Tep::Sock.sphttp_close(client_fd)
    Tep::Sock.sphttp_close(listener)
    bytes
  end

  def read_to_eof(fd)
    bytes = +""
    while true
      chunk = Tep::Sock.sphttp_recv_some(fd, 65536)
      break if chunk.length == 0
      bytes << chunk
    end
    bytes
  end

  def request_with(header_lines)
    "POST /up HTTP/1.1\r\nHost: localhost\r\n" + header_lines +
      "Connection: close\r\n\r\n"
  end

  # The status line of a response.
  def status_line(bytes)
    cut = bytes.index("\r\n")
    raise("no status line in " + bytes.inspect) if cut.nil?
    bytes[0, cut]
  end

  # A body larger than the cap is refused with 413 before any payload byte is
  # read, so the server does not wait for a body it will not keep.
  def test_a_body_over_the_cap_is_refused_with_413
    bytes = exchange(request_with("Content-Length: 99999999\r\n")) do |fd|
      serve_threaded(fd)
    end

    assert_equal "HTTP/1.0 413 Payload Too Large", status_line(bytes)
  end

  # A duplicated Content-Length is the classic request-smuggling shape: two
  # parsers can disagree on which value frames the body. The parser refuses the
  # request instead of letting the last value win.
  def test_a_duplicate_content_length_is_refused_with_400
    bytes = exchange(request_with("Content-Length: 5\r\nContent-Length: 6\r\n")) do |fd|
      serve_threaded(fd)
    end

    assert_equal "HTTP/1.0 400 Bad Request", status_line(bytes)
  end

  # A non-digit Content-Length (`5x`, `+5`, `5, 5`) is ambiguous in the same
  # way and is refused.
  def test_a_non_digit_content_length_is_refused_with_400
    bytes = exchange(request_with("Content-Length: 5x\r\n")) do |fd|
      serve_threaded(fd)
    end

    assert_equal "HTTP/1.0 400 Bad Request", status_line(bytes)
  end

  # Bytes past the advertised body would be invisible to a proxy that frames
  # by Content-Length, but this parser would put them into params. Tep does not
  # pipeline, so the request is refused.
  def test_bytes_past_the_advertised_body_are_refused_with_400
    bytes = exchange("POST /up HTTP/1.1\r\nHost: localhost\r\nContent-Length: 5\r\nConnection: close\r\n\r\nAAAAABBBBB") do |fd|
      serve_threaded(fd)
    end

    assert_equal "HTTP/1.0 400 Bad Request", status_line(bytes)
  end

  # Tep frames bodies by Content-Length only, so a Transfer-Encoding (chunked
  # included) is refused rather than ignored.
  def test_a_transfer_encoding_header_is_refused_with_400
    bytes = exchange(request_with("Transfer-Encoding: chunked\r\n")) do |fd|
      serve_threaded(fd)
    end

    assert_equal "HTTP/1.0 400 Bad Request", status_line(bytes)
  end

  # A stalled body is bounded by the whole-body deadline: the timed wait reports
  # no readiness and the drain answers :timeout instead of waiting forever.
  def test_a_stalled_body_times_out
    req = Tep::Request.new
    req.req_headers["content-length"] = "5"

    assert_equal :timeout, req.consume_body_via_io(NeverReadyIo.new, -1)
  end

  # A body one byte over the cap is refused before reading; a body exactly at
  # the cap is still allowed through to the read, which the same stand-in then
  # times out — the contrast pins the boundary as `>`.
  def test_the_cap_boundary_allows_exactly_the_maximum
    over = Tep::Request.new
    over.req_headers["content-length"] = (Tep::Request::MAX_BODY_BYTES + 1).to_s
    assert_equal :too_large, over.consume_body_via_io(NeverReadyIo.new, -1)

    at_cap = Tep::Request.new
    at_cap.req_headers["content-length"] = Tep::Request::MAX_BODY_BYTES.to_s
    assert_equal :timeout, at_cap.consume_body_via_io(NeverReadyIo.new, -1)
  end

  # A header with whitespace before the colon, an obs-fold continuation, a
  # line without a colon, or an empty name is malformed. Each is a shape an
  # upstream proxy can read differently than this parser, so none may be
  # silently ignored.
  def test_malformed_header_lines_are_refused_with_400
    space_before = exchange(request_with("Content-Length : 5\r\n")) do |fd|
      serve_threaded(fd)
    end
    assert_equal "HTTP/1.0 400 Bad Request", status_line(space_before)

    folded = exchange("POST /up HTTP/1.1\r\nHost: localhost\r\n Content-Length: 5\r\n\r\n") do |fd|
      serve_threaded(fd)
    end
    assert_equal "HTTP/1.0 400 Bad Request", status_line(folded)

    no_colon = exchange("POST /up HTTP/1.1\r\nHost: localhost\r\nBroken\r\n\r\n") do |fd|
      serve_threaded(fd)
    end
    assert_equal "HTTP/1.0 400 Bad Request", status_line(no_colon)

    empty_name = exchange(request_with(": value\r\n")) do |fd|
      serve_threaded(fd)
    end
    assert_equal "HTTP/1.0 400 Bad Request", status_line(empty_name)
  end

  # A Content-Length long enough to overflow a native integer parse is clamped
  # to the cap sentinel, so it reads as oversized rather than wrapping small.
  def test_a_very_long_content_length_is_clamped
    req = Tep::Request.new
    req.req_headers["content-length"] = "9999999999999999999999999999999999999999"

    assert_equal Tep::Request::MAX_BODY_BYTES + 1, req.content_length
  end

end

FixtureRunner.run(HttpRequestLimitsTest, [
  "test_a_body_over_the_cap_is_refused_with_413",
  "test_a_duplicate_content_length_is_refused_with_400",
  "test_a_non_digit_content_length_is_refused_with_400",
  "test_bytes_past_the_advertised_body_are_refused_with_400",
  "test_a_transfer_encoding_header_is_refused_with_400",
  "test_a_stalled_body_times_out",
  "test_the_cap_boundary_allows_exactly_the_maximum",
  "test_a_very_long_content_length_is_clamped",
  "test_malformed_header_lines_are_refused_with_400"
])
