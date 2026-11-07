require_relative "test_helper"
require_relative "harness_runner"

# Sqlx::Json (core) — the storage boundary for a schema-less
# json/jsonb column: `encode` takes the logical value to serialized
# TEXT, `decode` reads it back, and the pair is a bijection
# (`decode(encode(v)) == v`). Both directions are strict on purpose: a
# value JSON cannot represent raises instead of being silently to_s'd
# into the column, and a String payload is a JSON string — not the
# "already serialized" text the old passthrough assumed.
class JsonTest < TestBase
  def assert_equal(expected, actual, msg = nil)
    raise(msg || "expected #{expected.inspect}, got #{actual.inspect}") unless expected == actual
  end

  def argument_error?
    begin
      yield
    rescue ArgumentError
      return true
    end
    false
  end

  # Round trip: a nested Hash encodes to TEXT and reads back equal.
  def test_hash_round_trip
    text = Sqlx::Json.encode({ "a" => 1, "b" => [ true, nil ] })
    assert_equal "{\"a\":1,\"b\":[true,null]}", text
    assert_equal({ "a" => 1, "b" => [ true, nil ] }, Sqlx::Json.decode(text))
  end

  # A scalar payload is JSON too — the codec does not assume an object.
  def test_scalar_round_trip
    assert_equal "1", Sqlx::Json.encode(1)
    assert_equal 1, Sqlx::Json.decode("1")
    assert_equal "true", Sqlx::Json.encode(true)
    assert_equal 1.5, Sqlx::Json.decode("1.5")
  end

  # A String is a JSON string. The old passthrough stored a bare `hi`
  # (invalid JSON the decoder then could not read back) — the bijection
  # is what replaces that guess.
  def test_string_is_a_json_string
    assert_equal "\"hi\"", Sqlx::Json.encode("hi")
    assert_equal "hi", Sqlx::Json.decode(Sqlx::Json.encode("hi"))
  end

  # Hash keys read back as Strings — JSON objects have no symbol keys.
  def test_symbol_keys_become_strings
    assert_equal "{\"a\":1}", Sqlx::Json.encode({ a: 1 })
    assert_equal({ "a" => 1 }, Sqlx::Json.decode(Sqlx::Json.encode({ a: 1 })))
  end

  # nil is NULL in both directions — an absent column is not the text
  # "null".
  def test_nil_is_null
    assert_equal nil, Sqlx::Json.encode(nil)
    assert_equal nil, Sqlx::Json.decode(nil)
  end

  # The predicate encode enforces, answerable on its own for untrusted
  # input. Non-finite floats are not JSON numbers, and a Time is not a
  # JSON value at all — the silent-to_s cases the walk exists to stop.
  def test_encodable_predicate
    assert_equal true, Sqlx::Json.encodable?(nil)
    assert_equal true, Sqlx::Json.encodable?({ "a" => [ 1, { "b" => true } ] })
    assert_equal true, Sqlx::Json.encodable?({ a: "1.5" })
    assert_equal false, Sqlx::Json.encodable?(Time.now)
    assert_equal false, Sqlx::Json.encodable?(Float::INFINITY)
  end

  # A value JSON cannot represent raises instead of being to_s'd into
  # the column — top level and nested alike (the json gem's fallback
  # would store a Time as text with no signal).
  def test_non_json_value_raises
    assert_equal true, argument_error? { Sqlx::Json.encode(Time.now) }
    assert_equal true, argument_error? { Sqlx::Json.encode({ "a" => [ Time.now ] }) }
    assert_equal true, argument_error? { Sqlx::Json.encode(Float::INFINITY) }
  end

  # decode takes serialized text. A logical value in hand is a caller
  # bug (there is nothing to decode), so it raises rather than guessing.
  def test_decode_rejects_a_non_string
    assert_equal true, argument_error? { Sqlx::Json.decode({ "a" => 1 }) }
  end

  # Malformed text raises the modeled, portable class rather than the
  # parser's own — the adapters' parsers differ and that constant is not
  # modeled on the strict target.
  def test_decode_malformed_raises_argument_error
    assert_equal true, argument_error? { Sqlx::Json.decode("hi") }
    assert_equal true, argument_error? { Sqlx::Json.decode("{\"a\":") }
  end
end

FixtureRunner.run(JsonTest, [
  "test_hash_round_trip",
  "test_scalar_round_trip",
  "test_string_is_a_json_string",
  "test_symbol_keys_become_strings",
  "test_nil_is_null",
  "test_encodable_predicate",
  "test_non_json_value_raises",
  "test_decode_rejects_a_non_string",
  "test_decode_malformed_raises_argument_error"
])
