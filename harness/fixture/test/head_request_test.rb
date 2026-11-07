require_relative "test_helper"
require_relative "harness_runner"

# HTTP HEAD: the router maps it to the GET route it mirrors, and the servers
# answer with that response's status and headers and no body. The socket
# cases take the response bytes off the wire — a Net::HTTP client never reads
# a body from a HEAD response, so it cannot show a server that sent one.
class HeadRequestTest < TestBase
  def assert_equal(expected, actual)
    raise("expected #{expected.inspect}, got #{actual.inspect}") unless expected == actual
  end

  # The default server's connection loop on the accepted end of the pair:
  # read the request, dispatch it, write the answer, close the connection.
  def serve_threaded(fd)
    Tep::Server::Threaded.new.send(:handle_connection, fd)
  end

  # The fiber-mode server's write path on the accepted end of the pair. Its
  # read path parks on the cooperative scheduler, which has no place in this
  # case, so the request and response travel already built. This path does
  # not run the connection loop, which is what closes the fd.
  def serve_scheduled(fd, req, res)
    Tep::Server::Scheduled.new.send(:write_response, fd, req, res, false)
    Tep::Sock.sphttp_close(fd)
  end

  # One request/response exchange over a loopback socket pair: the request
  # bytes go in on the client end — nil when the server half is handed a
  # request object instead — the caller's server half runs on the accepted
  # end and closes it, and the response bytes come back through to that
  # close.
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

  # One request line, host, and close — the shape a monitor or proxy sends
  # when it wants only the headers.
  def raw_request(verb, path)
    verb + " " + path + " HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
  end

  # A parsed request for the in-process cases, the way the parser hands one
  # to dispatch.
  def build_request(verb, path)
    req = Tep::Request.new
    req.verb = verb
    req.path = path
    req.raw_path = path
    req.remote_host = +"127.0.0.1"
    req
  end

  # The status line with headers, then the body after the terminator.
  def split_response(bytes)
    cut = bytes.index("\r\n\r\n")
    raise("no header terminator in " + bytes.inspect) if cut.nil?
    [bytes[0, cut], bytes[cut + 4, bytes.length]]
  end

  # One header's value, "" when the response does not carry it.
  def header_value(headers, name)
    prefix = name + ": "
    lines = headers.split("\r\n")
    i = 0
    while i < lines.length
      line = lines[i]
      return line[prefix.length, line.length] if line.start_with?(prefix)
      i += 1
    end
    ""
  end

  # A HEAD on a routed path answers with the GET response's status line,
  # content type, and content length, with no body. The GET beside it is
  # what makes the content length mean something: it is the body length the
  # HEAD client would have read.
  def test_head_route_answers_with_the_get_headers_and_no_body
    get_bytes = exchange(raw_request("GET", "/up")) { |fd| serve_threaded(fd) }
    head_bytes = exchange(raw_request("HEAD", "/up")) { |fd| serve_threaded(fd) }
    get_parts = split_response(get_bytes)
    head_parts = split_response(head_bytes)
    get_headers = get_parts[0]
    get_body = get_parts[1]
    head_headers = head_parts[0]
    head_body = head_parts[1]

    assert_equal "HTTP/1.1 200 OK", head_headers.split("\r\n")[0]
    assert_equal header_value(get_headers, "Content-Type"),
                 header_value(head_headers, "Content-Type")
    assert_equal header_value(get_headers, "Content-Length"),
                 header_value(head_headers, "Content-Length")
    assert_equal '{"status":"ok"}', get_body
    assert_equal "", head_body
  end

  # A HEAD on a path no route matches answers 404 with the same content
  # length the GET miss would get, and no body: a route miss is its own
  # branch in the dispatcher, so it needs its own proof.
  def test_head_on_an_unmatched_path_is_404_without_a_body
    get_bytes = exchange(raw_request("GET", "/no-such-route")) { |fd| serve_threaded(fd) }
    head_bytes = exchange(raw_request("HEAD", "/no-such-route")) { |fd| serve_threaded(fd) }
    get_parts = split_response(get_bytes)
    head_parts = split_response(head_bytes)
    get_headers = get_parts[0]
    get_body = get_parts[1]
    head_headers = head_parts[0]
    head_body = head_parts[1]

    assert_equal "HTTP/1.1 404 Not Found", head_headers.split("\r\n")[0]
    assert_equal header_value(get_headers, "Content-Length"),
                 header_value(head_headers, "Content-Length")
    assert_equal '{"error":"not_found"}', get_body
    assert_equal "", head_body
  end

  # The action sees the request it was sent: HEAD stays HEAD through the
  # dispatcher instead of being rewritten to GET on the way in.
  def test_head_reaches_the_action_as_head
    HarnessCurrentProbeController.reset
    res = Tep::Response.new
    Snails::Main.dispatch(build_request("HEAD", "/current-probe"), res)

    assert_equal 200, res.status
    assert_equal true, HarnessCurrentProbeController.seen_request.head?
  end

  # The framing decision is made at the dispatch seam every server passes
  # through: a HEAD request leaves the response headers-only, a GET does not.
  # The write paths read that flag instead of asking the request for its verb.
  def test_dispatch_marks_a_head_response_headers_only
    head_res = Tep::Response.new
    Tep::APP.dispatch(build_request("HEAD", "/up"), head_res)
    get_res = Tep::Response.new
    Tep::APP.dispatch(build_request("GET", "/up"), get_res)

    assert_equal 200, head_res.status
    assert_equal true, head_res.headers_only
    assert_equal false, get_res.headers_only
  end

  # The route table carries GET rows only: HEAD reaches a route through the
  # dispatcher's mapping, not through a second declaration an app would have
  # to keep in step with the first.
  def test_route_table_declares_no_head_rows
    head_rows = 0
    Snails::Main.route_table.each do |route|
      head_rows += 1 if route.verb == "HEAD"
    end
    assert_equal 0, head_rows
  end

  # The fiber-mode server's write path obeys the framing decision the seam
  # makes: with `headers_only` the same status line and content length go
  # out and the body does not. The control carries the same HEAD request
  # without the flag and gets the body, so the writer suppresses on the flag
  # rather than on the request's verb.
  def test_scheduled_server_obeys_the_headers_only_response
    req = build_request("HEAD", "/up")
    req.http_version = "HTTP/1.1"

    control = Tep::Response.new
    control.status = 200
    control.body = '{"status":"ok"}'
    control_bytes = exchange(nil) { |fd| serve_scheduled(fd, req, control) }
    control_parts = split_response(control_bytes)

    flagged = Tep::Response.new
    flagged.status = 200
    flagged.body = '{"status":"ok"}'
    flagged.headers_only = true
    flagged_bytes = exchange(nil) { |fd| serve_scheduled(fd, req, flagged) }
    parts = split_response(flagged_bytes)
    headers = parts[0]
    body = parts[1]

    assert_equal '{"status":"ok"}', control_parts[1]
    assert_equal "HTTP/1.1 200 OK", headers.split("\r\n")[0]
    assert_equal "15", header_value(headers, "Content-Length")
    assert_equal "", body
  end
end

FixtureRunner.run(HeadRequestTest, [
  "test_head_route_answers_with_the_get_headers_and_no_body",
  "test_head_on_an_unmatched_path_is_404_without_a_body",
  "test_head_reaches_the_action_as_head",
  "test_dispatch_marks_a_head_response_headers_only",
  "test_route_table_declares_no_head_rows",
  "test_scheduled_server_obeys_the_headers_only_response"
])
