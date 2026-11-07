require_relative "test_helper"
require_relative "harness_runner"

# Request body parsing over the wire: a payload the runtime can read reaches
# the action as params, and one it cannot is a 400 — an action running against
# empty params (JSON), against the part before the break (multipart), or a
# missing required parameter escaping to the server as a 500 are all the
# client's mistake answered as the client's mistake. The socket cases run the
# threaded server's real handle_connection, so the parser, the body drain, and
# the dispatcher's answer are exercised together.
class RequestBodyParseTest < TestBase
  def assert_equal(expected, actual)
    raise("expected #{expected.inspect}, got #{actual.inspect}") unless expected == actual
  end

  # The threaded server's connection loop on the accepted end of the pair:
  # read the request, dispatch it, write the answer, close the connection.
  def serve_threaded(fd)
    Tep::Server::Threaded.new.send(:handle_connection, fd)
  end

  # One request/response exchange over a loopback socket pair: the request
  # bytes go in on the client end, the server half runs on the accepted end
  # and closes it, and the response bytes come back through to that close.
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

  # The response bytes through to the peer's close: the server half writes
  # its answer before closing, so the loop ends on EOF rather than on a
  # count it would have to guess.
  def read_to_eof(fd)
    bytes = +""
    while true
      chunk = Tep::Sock.sphttp_recv_some(fd, 65536)
      break if chunk.length == 0
      bytes << chunk
    end
    bytes
  end

  # The status line of a response.
  def status_line(bytes)
    cut = bytes.index("\r\n")
    raise("no status line in " + bytes.inspect) if cut.nil?
    bytes[0, cut]
  end

  # One POST carrying `body` as `content_type`, framed by Content-Length and
  # closed, so the exchange ends at the server's write.
  def post_request(content_type, body)
    "POST /body-params HTTP/1.1\r\nHost: localhost\r\n" +
      "Content-Type: " + content_type + "\r\n" +
      "Content-Length: " + body.bytesize.to_s + "\r\n" +
      "Connection: close\r\n\r\n" + body
  end

  # The status line of the answer to one POST.
  def post_status(content_type, body)
    bytes = exchange(post_request(content_type, body)) do |fd|
      serve_threaded(fd)
    end
    status_line(bytes)
  end

  # The answer's body — everything past the header terminator.
  def post_body(content_type, body)
    bytes = exchange(post_request(content_type, body)) do |fd|
      serve_threaded(fd)
    end
    cut = bytes.index("\r\n\r\n")
    raise("no header terminator in " + bytes.inspect) if cut.nil?
    bytes[cut + 4, bytes.length - cut - 4]
  end

  # The multipart shape a browser posts: the boundary, one named text part,
  # and the closing delimiter.
  def multipart_body
    "--AaB03x\r\n" +
      "Content-Disposition: form-data; name=\"name\"\r\n\r\n" +
      "ada\r\n" +
      "--AaB03x--\r\n"
  end

  # A JSON object body reaches the action as params — the control that says
  # the refusals below come from the payload, not from the route or the
  # server.
  def test_a_json_body_reaches_the_action
    assert_equal "HTTP/1.1 200 OK", post_status("application/json", '{"name":"ada"}')
    assert_equal true, post_body("application/json", '{"name":"ada"}').include?('"name":"ada"')
  end

  # Broken JSON used to leave the params empty for the action to refuse; the
  # client's mistake is answered here instead.
  def test_a_broken_json_body_is_a_400
    assert_equal "HTTP/1.1 400 Bad Request", post_status("application/json", '{"name":')
  end

  # A JSON body that is not an object carries no field names to read, so
  # there is nothing to build params from — refused like one that does not
  # parse.
  def test_a_json_body_that_is_not_an_object_is_a_400
    assert_equal "HTTP/1.1 400 Bad Request", post_status("application/json", '["ada"]')
  end

  # A body that parses but carries no required parameter reaches the action,
  # which refuses it: 400, not the 500 an uncaught ParameterMissing used to
  # become at the server.
  def test_a_missing_required_parameter_is_a_400
    assert_equal "HTTP/1.1 400 Bad Request", post_status("application/json", '{}')
  end

  # A well-formed multipart body reaches the action with its text part — the
  # control for the two refusals below.
  def test_a_multipart_body_reaches_the_action
    assert_equal "HTTP/1.1 200 OK", post_status("multipart/form-data; boundary=AaB03x", multipart_body)
    assert_equal true, post_body("multipart/form-data; boundary=AaB03x", multipart_body).include?('"name":"ada"')
  end

  # A multipart Content-Type without a boundary names no delimiter to split
  # on, so the body cannot be read at all.
  def test_a_multipart_body_without_a_boundary_is_a_400
    assert_equal "HTTP/1.1 400 Bad Request", post_status("multipart/form-data", multipart_body)
  end

  # A multipart body that stops before its closing delimiter used to leave
  # the parts found so far in params; the half-read form is refused instead.
  def test_a_truncated_multipart_body_is_a_400
    truncated = "--AaB03x\r\n" +
      "Content-Disposition: form-data; name=\"name\"\r\n\r\n" +
      "ada"
    assert_equal "HTTP/1.1 400 Bad Request", post_status("multipart/form-data; boundary=AaB03x", truncated)
  end
end

FixtureRunner.run(RequestBodyParseTest, [
  "test_a_json_body_reaches_the_action",
  "test_a_broken_json_body_is_a_400",
  "test_a_json_body_that_is_not_an_object_is_a_400",
  "test_a_missing_required_parameter_is_a_400",
  "test_a_multipart_body_reaches_the_action",
  "test_a_multipart_body_without_a_boundary_is_a_400",
  "test_a_truncated_multipart_body_is_a_400"
])
