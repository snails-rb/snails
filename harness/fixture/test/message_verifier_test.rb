require_relative "test_helper"
require_relative "harness_runner"

# Signed tokens and signed cookies: the verifier signs a String under a
# purpose-bound key and returns nil for a tampered, wrong-purpose, or
# wrong-secret token. `cookies.signed` uses the same verifier and keeps the
# transport options the app passed.
ENV["SECRET_KEY_BASE"] = "test-secret"
Snails.env = "test"

class MessageVerifierTest < TestBase
  def assert_equal(expected, actual)
    raise("expected #{expected.inspect}, got #{actual.inspect}") unless expected == actual
  end

  def assert_nil_value(actual)
    raise("expected nil, got #{actual.inspect}") unless actual.nil?
  end

  def assert_true(value)
    raise("expected true, got #{value.inspect}") unless value == true
  end

  def assert_includes(text, expected)
    raise("expected #{text.inspect} to include #{expected.inspect}") unless text.include?(expected)
  end

  def test_round_trip
    verifier = Snails::MessageVerifier.new("secret")
    token = verifier.generate("abc")
    assert_equal "abc", verifier.verified(token)
  end

  def test_tampered_token_returns_nil
    verifier = Snails::MessageVerifier.new("secret")
    token = verifier.generate("abc")
    assert_nil_value verifier.verified("x" + token)
  end

  def test_wrong_purpose_returns_nil
    verifier = Snails::MessageVerifier.new("secret")
    token = verifier.generate("abc", purpose: "reset")
    assert_equal "abc", verifier.verified(token, purpose: "reset")
    assert_nil_value verifier.verified(token, purpose: "cookie.session")
  end

  def test_wrong_secret_returns_nil
    verifier = Snails::MessageVerifier.new("secret")
    token = verifier.generate("abc")
    other = Snails::MessageVerifier.new("other")
    assert_nil_value other.verified(token)
  end

  # Equal Strings compare true; a byte difference or a length difference
  # compares false without running the byte loop for the shorter value.
  def test_secure_compare
    assert_true Snails::Security.secure_compare("abc", "abc")
    assert_equal false, Snails::Security.secure_compare("abc", "abd")
    assert_equal false, Snails::Security.secure_compare("abc", "abcd")
    begin
      Snails::Security.secure_compare("abc", nil)
      raise("expected ArgumentError")
    rescue ArgumentError
    end
  end

  # The fixed-length form raises on a length mismatch instead of returning
  # false.
  def test_fixed_length_secure_compare
    assert_true Snails::Security.fixed_length_secure_compare("abc", "abc")
    begin
      Snails::Security.fixed_length_secure_compare("abc", "abcd")
      raise("expected ArgumentError")
    rescue ArgumentError
    end
  end

  # A signed cookie uses a cookie-specific key, so a generic verifier token
  # with the same purpose string does not read as a signed cookie.
  def test_generic_token_does_not_verify_as_signed_cookie
    generic = Snails::MessageVerifier.new
    token = generic.generate("abc", purpose: "cookie.session")
    assert_equal "abc", generic.verified(token, purpose: "cookie.session")
    jar = ActionController::CookieJar.new({ "session" => token })
    assert_nil_value jar.signed[:session]
  end

  # A plain cookie is not a signed token.
  def test_unsigned_cookie_reads_nil
    jar = ActionController::CookieJar.new({ "session" => "abc" })
    assert_nil_value jar.signed[:session]
  end

  def test_signed_cookie_round_trip
    jar = ActionController::CookieJar.new
    jar.signed[:session] = "abc"
    assert_equal "abc", jar.signed[:session]
    assert_equal false, jar.raw(:session) == "abc"
  end

  def test_signed_cookie_tamper_returns_nil
    jar = ActionController::CookieJar.new
    jar.signed[:session] = "abc"
    tampered = ActionController::CookieJar.new({ "session" => "x" + jar.raw(:session) })
    assert_nil_value tampered.signed[:session]
  end

  def test_signed_cookie_other_name_returns_nil
    jar = ActionController::CookieJar.new
    jar.signed[:session] = "abc"
    other = ActionController::CookieJar.new({ "other" => jar.raw(:session) })
    assert_nil_value other.signed[:other]
  end

  def test_signed_cookie_keeps_options
    jar = ActionController::CookieJar.new
    jar.signed[:session] = {
      value: "abc",
      httponly: true,
      secure: true,
      same_site: :strict,
      path: "/"
    }
    write = jar.pending[0]
    assert_equal "", write.options["HttpOnly"]
    assert_equal "", write.options["Secure"]
    assert_equal "Strict", write.options["SameSite"]
    assert_equal false, write.value == "abc"
  end

  def test_signed_permanent_sets_expiry
    jar = ActionController::CookieJar.new
    jar.signed.permanent[:session] = "abc"
    write = jar.pending[0]
    assert_equal true, write.options.key?("Expires")
  end

  def test_signed_delete_clears_the_value
    jar = ActionController::CookieJar.new
    jar.signed[:session] = "abc"
    jar.signed.delete(:session, path: "/")
    assert_equal "", jar.raw(:session)
  end

  # A signed empty String is still a valid signed value; an absent cookie
  # remains nil.
  def test_signed_empty_value_round_trip
    jar = ActionController::CookieJar.new
    jar.signed[:session] = ""
    assert_equal "", jar.signed[:session]
  end

  # A signed write Hash without `value:` fails at the call site and names
  # the signed surface.
  def test_signed_hash_without_value_is_rejected
    jar = ActionController::CookieJar.new
    begin
      jar.signed[:session] = { httponly: true }
      raise("expected ArgumentError")
    rescue ArgumentError => e
      assert_includes e.message, "cookies.signed"
    end
  end

  # A malformed token reads nil: no separator, no payload, and an empty
  # signature all fail without raising.
  def test_malformed_token_returns_nil
    verifier = Snails::MessageVerifier.new("secret")
    assert_nil_value verifier.verified("")
    assert_nil_value verifier.verified("abc")
    assert_nil_value verifier.verified("abc.")
  end
end

FixtureRunner.run(MessageVerifierTest, [
  "test_round_trip",
  "test_tampered_token_returns_nil",
  "test_wrong_purpose_returns_nil",
  "test_wrong_secret_returns_nil",
  "test_secure_compare",
  "test_fixed_length_secure_compare",
  "test_generic_token_does_not_verify_as_signed_cookie",
  "test_unsigned_cookie_reads_nil",
  "test_signed_cookie_round_trip",
  "test_signed_cookie_tamper_returns_nil",
  "test_signed_cookie_other_name_returns_nil",
  "test_signed_cookie_keeps_options",
  "test_signed_permanent_sets_expiry",
  "test_signed_delete_clears_the_value",
  "test_signed_empty_value_round_trip",
  "test_signed_hash_without_value_is_rejected",
  "test_malformed_token_returns_nil",
])
