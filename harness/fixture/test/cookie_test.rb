require_relative "test_helper"
require_relative "harness_runner"

# Cookies are HTTP transport: the request's parsed hash reaches
# `request.cookies`, the controller jar reads the same inbound values, and
# every write becomes one `Set-Cookie` line with the attributes the app
# asked for. A read after a delete must not see the deleted inbound value.
Snails.env = "test"

class CookieTest < TestBase
  def assert_equal(expected, actual)
    raise("expected #{expected.inspect}, got #{actual.inspect}") unless expected == actual
  end

  def assert_includes(text, expected)
    raise("expected #{text.inspect} to include #{expected.inspect}") unless text.include?(expected)
  end

  def build_request(path)
    req = Tep::Request.new
    req.verb = "GET"
    req.path = path
    req.raw_path = path
    req.remote_host = +"127.0.0.1"
    req
  end

  # A request cookie reaches both the request hash and the controller jar;
  # a missing cookie reads "" in both.
  def test_inbound_cookie_reaches_request_and_jar
    req = build_request("/cookie-read")
    req.cookies["session"] = "abc"
    res = Tep::Response.new
    Snails::Main.dispatch(req, res)

    assert_equal 200, res.status
    assert_equal '{"request":"abc","jar":"abc","missing":""}', res.body
  end

  # Two writes produce two lines; each carries its own attributes, and a
  # plain value gets the jar defaults (Path=/ and SameSite=Lax).
  def test_write_emits_multiple_set_cookie_lines_with_options
    res = Tep::Response.new
    Snails::Main.dispatch(build_request("/cookie-write"), res)

    assert_equal 204, res.status
    assert_equal 2, res.set_cookies.length
    first = res.set_cookies[0]
    second = res.set_cookies[1]
    assert_equal true, first.start_with?("session=abc%20123%3B")
    assert_includes first, "Path=/"
    assert_includes first, "Max-Age=3600"
    assert_includes first, "Secure"
    assert_includes first, "HttpOnly"
    assert_includes first, "SameSite=Strict"
    assert_equal true, second.start_with?("second=two")
    assert_includes second, "Path=/"
    assert_includes second, "SameSite=Lax"
  end

  # `cookies.delete` emits a cleared value with Max-Age=0 and an epoch
  # Expires, so the browser removes the cookie instead of keeping the old
  # value.
  def test_delete_emits_cleared_cookie
    res = Tep::Response.new
    Snails::Main.dispatch(build_request("/cookie-delete"), res)

    assert_equal 1, res.set_cookies.length
    line = res.set_cookies[0]
    assert_equal true, line.start_with?("session=")
    assert_includes line, "Max-Age=0"
    assert_includes line, "Expires="
  end

  # `cookies.permanent` adds a far-future Expires to a write.
  def test_permanent_sets_expiry
    res = Tep::Response.new
    Snails::Main.dispatch(build_request("/cookie-permanent"), res)

    assert_equal 1, res.set_cookies.length
    line = res.set_cookies[0]
    assert_equal true, line.start_with?("session=forever")
    assert_includes line, "Expires="
  end

  # A read after a delete returns "" even though the inbound cookie held a
  # value — the cleared write takes precedence over the inbound value.
  def test_delete_wins_over_inbound_on_read
    jar = ActionController::CookieJar.new({ "session" => "abc" })
    jar.delete("session")
    assert_equal "", jar["session"]
  end

  # The __Host- prefix rules are browser rules; a violation is a loud
  # ArgumentError here instead of a silently dropped cookie.
  def test_host_prefix_requires_secure_path_and_no_domain
    jar = ActionController::CookieJar.new
    begin
      jar["__Host-session"] = { value: "v", path: "/", domain: "example.com" }
      raise("expected ArgumentError")
    rescue ArgumentError => e
      assert_includes e.message, "__Host-"
    end
    begin
      jar["__Host-session"] = { value: "v", path: "/" }
      raise("expected ArgumentError")
    rescue ArgumentError => e
      assert_includes e.message, "__Host-"
    end
    jar["__Host-session"] = { value: "v", path: "/", secure: true }
    assert_equal 1, jar.pending.length
  end

  # SameSite=None is only legal on a Secure cookie.
  def test_same_site_none_requires_secure
    jar = ActionController::CookieJar.new
    begin
      jar["session"] = { value: "v", same_site: :none }
      raise("expected ArgumentError")
    rescue ArgumentError => e
      assert_includes e.message, "SameSite"
    end
    jar["session"] = { value: "v", same_site: :none, secure: true }
    assert_equal 1, jar.pending.length
  end

  # A misspelled option must not silently drop the flag.
  def test_unknown_option_is_rejected
    jar = ActionController::CookieJar.new
    begin
      jar["session"] = { value: "v", http_only: true }
      raise("expected ArgumentError")
    rescue ArgumentError => e
      assert_includes e.message, "unknown cookie option"
    end
  end

  # A missing cookie reads "" rather than nil; presence is a key? question
  # on `request.cookies`.
  def test_missing_cookie_reads_empty_string
    jar = ActionController::CookieJar.new
    assert_equal "", jar["missing"]
  end

  # A cookie name is an RFC 6265 token: separators, control bytes, and
  # non-ASCII characters fail at the write.
  def test_cookie_name_rejects_token_separators
    jar = ActionController::CookieJar.new
    begin
      jar["a:b"] = "v"
      raise("expected ArgumentError")
    rescue ArgumentError => e
      assert_includes e.message, "cookie name"
    end
    begin
      jar["a(b"] = "v"
      raise("expected ArgumentError")
    rescue ArgumentError => e
      assert_includes e.message, "cookie name"
    end
    begin
      jar["a\x7F"] = "v"
      raise("expected ArgumentError")
    rescue ArgumentError => e
      assert_includes e.message, "cookie name"
    end
  end

  # Path and domain are written into `Set-Cookie` without escaping; a
  # semicolon or CR/LF there would add an attribute or a header line, so the
  # jar rejects it.
  def test_path_and_domain_reject_header_characters
    jar = ActionController::CookieJar.new
    begin
      jar["session"] = { value: "v", path: "/; Secure" }
      raise("expected ArgumentError")
    rescue ArgumentError => e
      assert_includes e.message, "cookie path"
    end
    begin
      jar["session"] = { value: "v", domain: "example.com; HttpOnly" }
      raise("expected ArgumentError")
    rescue ArgumentError => e
      assert_includes e.message, "cookie domain"
    end
    begin
      jar["session"] = { value: "v", path: "/\r\nX-Evil: 1" }
      raise("expected ArgumentError")
    rescue ArgumentError => e
      assert_includes e.message, "cookie path"
    end
    begin
      jar["session"] = { value: "v", domain: "example.com\r\nX-Evil: 1" }
      raise("expected ArgumentError")
    rescue ArgumentError => e
      assert_includes e.message, "cookie domain"
    end
  end

  # A valid path and domain still write; validation must not reject ordinary
  # values.
  def test_valid_path_and_domain_are_accepted
    jar = ActionController::CookieJar.new
    jar["session"] = { value: "v", path: "/app", domain: ".example.com" }
    assert_equal 1, jar.pending.length
  end

  # The __Secure- prefix only needs Secure; a rule violation fails at the
  # write.
  def test_secure_prefix_requires_secure
    jar = ActionController::CookieJar.new
    begin
      jar["__Secure-session"] = { value: "v" }
      raise("expected ArgumentError")
    rescue ArgumentError => e
      assert_includes e.message, "__Secure-"
    end
    jar["__Secure-session"] = { value: "v", secure: true }
    assert_equal 1, jar.pending.length
  end

  # The base jar's `to_h` merges inbound values with pending writes; a
  # cleared write appears as an empty string.
  def test_to_h_merges_inbound_and_pending_writes
    jar = ActionController::CookieJar.new({ "inbound" => "keep", "session" => "old" })
    jar["session"] = "new"
    jar.delete("gone")
    merged = jar.to_h
    assert_equal "keep", merged["inbound"]
    assert_equal "new", merged["session"]
    assert_equal "", merged["gone"]
    assert_equal 3, merged.length
  end

  # `each` walks the snapshot `to_h` builds; a write in the block does not
  # join the current walk.
  def test_each_walks_the_snapshot
    jar = ActionController::CookieJar.new({ "session" => "abc" })
    seen = []
    jar.each do |name, value|
      seen.push(name + "=" + value)
      jar["later"] = "no"
    end
    assert_equal 1, seen.length
    assert_equal "session=abc", seen[0]
    assert_equal "no", jar["later"]
  end
end

FixtureRunner.run(CookieTest, [
  "test_inbound_cookie_reaches_request_and_jar",
  "test_write_emits_multiple_set_cookie_lines_with_options",
  "test_delete_emits_cleared_cookie",
  "test_permanent_sets_expiry",
  "test_delete_wins_over_inbound_on_read",
  "test_host_prefix_requires_secure_path_and_no_domain",
  "test_same_site_none_requires_secure",
  "test_unknown_option_is_rejected",
  "test_missing_cookie_reads_empty_string",
  "test_cookie_name_rejects_token_separators",
  "test_path_and_domain_reject_header_characters",
  "test_valid_path_and_domain_are_accepted",
  "test_secure_prefix_requires_secure",
  "test_to_h_merges_inbound_and_pending_writes",
  "test_each_walks_the_snapshot",
])
