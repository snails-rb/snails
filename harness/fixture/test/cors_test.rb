require_relative "test_helper"
require_relative "harness_runner"

# CORS at the dispatch boundary: a preflight is answered before routing and
# auth, actual responses carry the allow headers, a denied origin gets no
# allow header, and the server's 500 keeps the headers the dispatch placed.
class CorsTest < TestBase
  def assert_equal(expected, actual)
    raise("expected #{expected.inspect}, got #{actual.inspect}") unless expected == actual
  end

  def assert_includes(text, expected)
    raise("expected #{text.inspect} to include #{expected.inspect}") unless text.include?(expected)
  end

  def assert_true(value)
    raise("expected true, got #{value.inspect}") unless value == true
  end

  def assert_absent(headers, name)
    raise("expected #{name.inspect} to be absent") if headers.key?(name)
  end

  def build_request(verb, path)
    req = Tep::Request.new
    req.verb = verb
    req.path = path
    req.raw_path = path
    req.remote_host = +"127.0.0.1"
    req
  end

  def preflight_request(origin, method, headers = nil)
    req = build_request("OPTIONS", "/current-probe")
    req.req_headers["origin"] = origin
    req.req_headers["access-control-request-method"] = method
    req.req_headers["access-control-request-headers"] = headers unless headers.nil?
    req
  end

  # The threaded server's connection loop on the accepted end of the pair.
  def serve_threaded(fd)
    Tep::Server::Threaded.new.send(:handle_connection, fd)
  end

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

    Tep::Sock.sphttp_write_str(client_fd, request)
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

  def status_line(bytes)
    cut = bytes.index("\r\n")
    raise("no status line in " + bytes.inspect) if cut.nil?
    bytes[0, cut]
  end

  # A preflight to an allowed origin, method, and header is answered before
  # routing: 204, the policy's headers, and no controller.
  def test_preflight_is_answered_before_routing
    HarnessCurrentProbeController.reset
    res = Tep::Response.new
    Tep::APP.dispatch(preflight_request("https://app.example.com", "GET", "Content-Type"), res)

    assert_equal 204, res.status
    assert_equal "", res.body
    assert_equal "https://app.example.com", res.headers["Access-Control-Allow-Origin"]
    assert_equal "GET, POST", res.headers["Access-Control-Allow-Methods"]
    assert_equal "Content-Type", res.headers["Access-Control-Allow-Headers"]
    assert_equal "true", res.headers["Access-Control-Allow-Credentials"]
    assert_equal "600", res.headers["Access-Control-Max-Age"]
    assert_true res.headers["Vary"].include?("Origin")
    raise("preflight reached the controller") unless HarnessCurrentProbeController.seen_request.nil?
  end

  # A denied origin is still answered as a preflight, with no allow header.
  def test_denied_origin_gets_no_allow_header
    res = Tep::Response.new
    Tep::APP.dispatch(preflight_request("https://evil.example.com", "GET", "Content-Type"), res)

    assert_equal 204, res.status
    assert_absent res.headers, "Access-Control-Allow-Origin"
    assert_true res.headers["Vary"].include?("Origin")
  end

  # A method outside the policy and a header outside the policy are denied
  # the same way.
  def test_denied_method_and_header_get_no_allow_header
    method_res = Tep::Response.new
    Tep::APP.dispatch(preflight_request("https://app.example.com", "DELETE"), method_res)
    assert_equal 204, method_res.status
    assert_absent method_res.headers, "Access-Control-Allow-Origin"

    header_res = Tep::Response.new
    Tep::APP.dispatch(preflight_request("https://app.example.com", "GET", "Authorization"), header_res)
    assert_equal 204, header_res.status
    assert_absent header_res.headers, "Access-Control-Allow-Origin"
  end

  # An actual response from an allowed origin carries the allow headers and
  # the origin Vary; the controller still runs.
  def test_actual_response_carries_allow_headers
    HarnessCurrentProbeController.reset
    req = build_request("GET", "/current-probe")
    req.req_headers["origin"] = "https://app.example.com"
    res = Tep::Response.new
    Tep::APP.dispatch(req, res)

    assert_equal 200, res.status
    assert_equal "https://app.example.com", res.headers["Access-Control-Allow-Origin"]
    assert_equal "true", res.headers["Access-Control-Allow-Credentials"]
    assert_equal "X-Total-Count", res.headers["Access-Control-Expose-Headers"]
    assert_true res.headers["Vary"].include?("Origin")
    raise("controller did not run") if HarnessCurrentProbeController.seen_request.nil?
  end

  # A Vary value that differs only by case is already present; applying CORS
  # does not add a duplicate.
  def test_vary_merge_is_case_insensitive
    req = build_request("GET", "/current-probe")
    req.req_headers["origin"] = "https://app.example.com"
    res = Tep::Response.new
    res.headers["Vary"] = "origin"
    Snails::Cors.apply(req, res)
    assert_equal "origin", res.headers["Vary"]
    assert_equal "https://app.example.com", res.headers["Access-Control-Allow-Origin"]
  end

  # The framework's 404 still carries the allow headers.
  def test_route_miss_carries_allow_headers
    req = build_request("GET", "/nope")
    req.req_headers["origin"] = "https://app.example.com"
    res = Tep::Response.new
    Tep::APP.dispatch(req, res)

    assert_equal 404, res.status
    assert_equal "https://app.example.com", res.headers["Access-Control-Allow-Origin"]
  end

  # A raised action becomes the server's simple 500, which keeps the
  # response headers the dispatch placed before the action ran.
  def test_server_500_keeps_the_cors_headers
    bytes = exchange(
      "GET /boom HTTP/1.1\r\nHost: localhost\r\n" \
      "Origin: https://app.example.com\r\nConnection: close\r\n\r\n"
    ) { |fd| serve_threaded(fd) }

    assert_equal "HTTP/1.0 500 Internal Server Error", status_line(bytes)
    assert_includes bytes, "Access-Control-Allow-Origin: https://app.example.com"
    assert_includes bytes, "Vary: Origin"
  end

  # Policy validation rejects the combinations the Fetch rules forbid.
  def test_policy_rejects_wildcard_with_credentials
    begin
      Snails::Cors::Policy.new(["*"], ["GET"], [], true)
      raise("expected ArgumentError")
    rescue ArgumentError
    end
  end

  def test_policy_rejects_mixed_wildcard
    begin
      Snails::Cors::Policy.new(["*", "https://app.example.com"], ["GET"])
      raise("expected ArgumentError")
    rescue ArgumentError
    end
  end

  def test_policy_rejects_an_empty_list
    begin
      Snails::Cors::Policy.new([], ["GET"])
      raise("expected ArgumentError")
    rescue ArgumentError
    end
  end

  def test_setter_rejects_a_non_policy
    raised = false
    begin
      Snails.cors = "nope"
    rescue TypeError
      raised = true
    rescue ArgumentError
      raised = true
    end
    raise("expected TypeError or ArgumentError") unless raised
  end
end

FixtureRunner.run(CorsTest, [
  "test_preflight_is_answered_before_routing",
  "test_denied_origin_gets_no_allow_header",
  "test_denied_method_and_header_get_no_allow_header",
  "test_actual_response_carries_allow_headers",
  "test_vary_merge_is_case_insensitive",
  "test_route_miss_carries_allow_headers",
  "test_server_500_keeps_the_cors_headers",
  "test_policy_rejects_wildcard_with_credentials",
  "test_policy_rejects_mixed_wildcard",
  "test_policy_rejects_an_empty_list",
  "test_setter_rejects_a_non_policy",
])
