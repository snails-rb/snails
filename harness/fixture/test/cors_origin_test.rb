require_relative "test_helper"
require_relative "harness_runner"

# The CORS policy's origin predicate: apps reuse it for the Origin check on
# state-changing requests, so it must match exactly what the dispatcher
# matches and must never turn a missing Origin into an allowed one.
class CorsOriginTest < TestBase
  def assert_equal(expected, actual)
    raise("expected #{expected.inspect}, got #{actual.inspect}") unless expected == actual
  end

  def policy(origins)
    Snails::Cors::Policy.new(origins: origins, allowed_methods: ["GET"])
  end

  # A named policy matches its exact origin strings only.
  def test_named_origins_match_exactly
    cors = policy(["https://app.example.com"])
    assert_equal true, cors.origin_allowed?("https://app.example.com")
    assert_equal false, cors.origin_allowed?("https://evil.example.com")
    assert_equal false, cors.origin_allowed?("https://app.example.com/")
    assert_equal false, cors.origin_allowed?("HTTPS://app.example.com")
    assert_equal false, cors.origin_allowed?(nil)
    assert_equal false, cors.origin_allowed?("")
  end

  # A wildcard policy allows any named origin but not a missing or empty one.
  def test_wildcard_does_not_allow_a_missing_origin
    cors = policy(["*"])
    assert_equal true, cors.origin_allowed?("https://any.example.com")
    assert_equal true, cors.origin_allowed?("null")
    assert_equal false, cors.origin_allowed?(nil)
    assert_equal false, cors.origin_allowed?("")
  end

  # The serialized null origin is a literal policy value, not a wildcard.
  def test_null_origin_is_literal
    cors = policy(["null"])
    assert_equal true, cors.origin_allowed?("null")
    assert_equal false, cors.origin_allowed?("https://app.example.com")
    assert_equal false, cors.origin_allowed?(nil)
  end
end

FixtureRunner.run(CorsOriginTest, [
  "test_named_origins_match_exactly",
  "test_wildcard_does_not_allow_a_missing_origin",
  "test_null_origin_is_literal"
])
