require_relative "test_helper"
require_relative "harness_runner"

# The controller HTTP authentication entry points — token/basic parsing and
# the private parser behind them.
class HttpAuthenticationTest < TestBase
  def assert_equal(expected, actual)
    raise("expected #{expected.inspect}, got #{actual.inspect}") unless expected == actual
  end

  def controller_with(header)
    c = ActionController::API.new
    c.request = ActionDispatch::Request.for({ "HTTP_AUTHORIZATION" => header })
    c
  end

  # Token auth yields the token and the `key=value` options after it.
  def test_token_authentication
    c = controller_with("Token abc123; other=42")
    seen = []
    result = c.authenticate_with_http_token do |token, options|
      seen << token
      seen << options["other"]
      "ok"
    end
    assert_equal "ok", result
    assert_equal ["abc123", "42"], seen
  end

  # Basic auth yields the decoded user and password, split at the first colon.
  def test_basic_authentication
    c = controller_with("Basic " + Base64.strict_encode64("alice:secret"))
    seen = []
    result = c.authenticate_with_http_basic do |user, password|
      seen << user
      seen << password
      "ok"
    end
    assert_equal "ok", result
    assert_equal ["alice", "secret"], seen
  end

  # The parser helpers are private instance methods; an app calling one from
  # outside is refused.
  def test_parser_helpers_are_private
    c = controller_with("Token x")
    message = ""
    begin
      c.token_from("Token x")
    rescue NoMethodError => e
      message = e.message
    end
    assert_equal true, message.include?("private method")
  end
end

FixtureRunner.run(HttpAuthenticationTest, [
  "test_token_authentication",
  "test_basic_authentication",
  "test_parser_helpers_are_private"
])
