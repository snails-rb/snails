require_relative "test_helper"
require_relative "harness_runner"

# The request's header view — HTTP names map to the internal Rack-style keys,
# lookup is case-insensitive, and iteration stays header-only.
class RequestHeadersTest < TestBase
  def assert_equal(expected, actual)
    raise("expected #{expected.inspect}, got #{actual.inspect}") unless expected == actual
  end

  def assert_nil(actual)
    raise("expected nil, got #{actual.inspect}") unless actual.nil?
  end

  def build_request(env)
    ActionDispatch::Request.new(env)
  end

  # `Authorization` and `Content-Type` map to the CGI/Rack keys, and lookup
  # accepts the header name in any case or the env key directly.
  def test_header_names_are_case_insensitive_and_mapped
    request = build_request({
      "HTTP_AUTHORIZATION" => "Bearer token",
      "CONTENT_TYPE" => "application/json",
    })
    headers = request.headers
    assert_equal "Bearer token", headers["Authorization"]
    assert_equal "Bearer token", headers["authorization"]
    assert_equal "Bearer token", headers["HTTP_AUTHORIZATION"]
    assert_equal "application/json", headers["Content-Type"]
    assert_equal "application/json", headers["CONTENT_TYPE"]
  end

  # A missing header reads nil and `has_key?` is false; an empty value is present.
  def test_missing_and_empty_headers_are_distinct
    request = build_request({ "HTTP_X_EMPTY" => "" })
    headers = request.headers
    assert_nil headers["X-Missing"]
    assert_equal false, headers.has_key?("X-Missing")
    assert_equal "", headers["X-Empty"]
    assert_equal true, headers.has_key?("X-Empty")
  end

  # `fetch` raises when the header is absent and answers the default when one
  # is given.
  def test_fetch_raises_or_returns_the_default
    headers = build_request({ "HTTP_X_PRESENT" => "value" }).headers
    assert_equal "value", headers.fetch("X-Present")
    raised = false
    begin
      headers.fetch("X-Missing")
    rescue KeyError
      raised = true
    end
    assert_equal true, raised
    assert_equal "fallback", headers.fetch("X-Missing", "fallback")
  end

  # `each_header` yields only header keys, with names normalized to lowercase
  # dashes; env scratch keys are skipped.
  def test_each_header_yields_only_normalized_headers
    request = build_request({
      "HTTP_X_CUSTOM" => "custom",
      "CONTENT_TYPE" => "application/json",
      "scratch" => "not-a-header",
    })
    seen = {}
    request.headers.each_header { |name, value| seen[name] = value }
    assert_equal 2, seen.size
    assert_equal "custom", seen["x-custom"]
    assert_equal "application/json", seen["content-type"]
    assert_equal false, seen.key?("scratch")
  end

  # `to_h` uses the same normalized names as `each`.
  def test_to_h_returns_normalized_header_names
    headers = build_request({ "HTTP_X_CUSTOM" => "custom" }).headers
    assert_equal "custom", headers.to_h["x-custom"]
  end

  # The constructor copies the env, so a caller mutating its hash afterwards
  # does not change the request.
  def test_constructor_copies_the_env
    env = { "HTTP_X_CUSTOM" => "before" }
    request = build_request(env)
    env["HTTP_X_CUSTOM"] = "after"
    assert_equal "before", request.headers["X-Custom"]
  end

  # The internal env hash is not a public accessor — apps read `headers`.
  def test_env_is_not_public
    request = build_request({ "HTTP_X_CUSTOM" => "custom" })
    assert_equal false, request.respond_to?(:env)
  end
end

FixtureRunner.run(RequestHeadersTest, [
  "test_header_names_are_case_insensitive_and_mapped",
  "test_missing_and_empty_headers_are_distinct",
  "test_fetch_raises_or_returns_the_default",
  "test_each_header_yields_only_normalized_headers",
  "test_to_h_returns_normalized_header_names",
  "test_constructor_copies_the_env",
  "test_env_is_not_public",
])
