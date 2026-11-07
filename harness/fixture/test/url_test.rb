require_relative "test_helper"
require_relative "harness_runner"

# Tep::Url — percent coding and query parsing, and the private hex helpers.
class UrlTest < TestBase
  def assert_equal(expected, actual)
    raise("expected #{expected.inspect}, got #{actual.inspect}") unless expected == actual
  end

  # The percent codec round-trips a space and a reserved byte; a plus in a
  # query string reads back as a space.
  def test_escape_and_unescape_round_trip
    assert_equal "a%20b%2Fc", Tep::Url.escape("a b/c")
    assert_equal "a b/c", Tep::Url.unescape("a%20b%2Fc")
    assert_equal "a b", Tep::Url.unescape("a+b")
  end

  # A percent-encoded multibyte character decodes to UTF-8 text, not an
  # ASCII-8BIT byte string that a JSON encoder would reject.
  def test_unescape_decodes_multibyte_to_utf8
    s = Tep::Url.unescape("%ED%95%9C%EA%B8%80")
    raise "expected UTF-8, got #{s.encoding}" unless s.encoding == Encoding::UTF_8
    raise "expected 2 characters, got #{s.length}" unless s.length == 2
    assert_equal "한글", s
  end

  # A literal multibyte character mixed with a percent escape decodes without
  # an encoding conflict.
  def test_unescape_mixes_literal_and_escaped_multibyte
    assert_equal "éé", Tep::Url.unescape("é%C3%A9")
  end

  # A query string becomes the flat hash the parser reads; a key with no
  # "=" carries an empty value.
  def test_parse_query_builds_a_flat_hash
    assert_equal({ "a" => "1", "b" => "2", "c" => "" }, Tep::Url.parse_query("a=1&b=2&c"))
  end

  # The hex helpers sit behind escape/unescape; an app calling one from
  # outside is refused.
  def test_hex_helpers_are_private
    begin
      Tep::Url.hex_nibble("a")
    rescue NoMethodError
      return
    end
    raise "expected Tep::Url.hex_nibble to be private"
  end
end

FixtureRunner.run(UrlTest, [
  "test_escape_and_unescape_round_trip",
  "test_unescape_decodes_multibyte_to_utf8",
  "test_unescape_mixes_literal_and_escaped_multibyte",
  "test_parse_query_builds_a_flat_hash",
  "test_hex_helpers_are_private"
])
