require_relative "test_helper"
require_relative "harness_runner"

# Snails ext (snails-core/ext) — the method extensions over the builtins.
# One case per reopened class: Integer time units, String helpers,
# Enumerable/Array collection helpers, Hash key transforms, Object
# blank-value predicates (the slice that needed the spinel Object-reopen
# fix — see snails-core/ext/object.rb), and Time date helpers (the slice that
# accepted the Time-slot boundary contract — snails-core/ext/time.rb).
class ExtTest < TestBase
  def assert_equal(expected, actual, msg = nil)
    raise(msg || "expected #{expected.inspect}, got #{actual.inspect}") unless expected == actual
  end

  # Units build the runtime Duration, so `.to_i` answers seconds and the
  # Duration instance methods (`ago`/`from_now`) carry the arithmetic.
  def test_integer_units_return_duration
    assert_equal 604_800, 7.days.to_i
    assert_equal 60, 1.minute.to_i
    assert_equal 1_209_600, 2.weeks.to_i
    assert_equal 31_556_952, 1.year.to_i
    assert_equal true, 7.days.ago < Time.now
  end

  # The text helpers: whitespace collapse, camel split, humanize,
  # titleize.
  def test_string_helpers
    assert_equal "a b", "  a   b  ".squish
    assert_equal "a b c", "a\tb\nc".squish
    assert_equal "foo_bar", "FooBar".underscore
    assert_equal "foo_bar", "foo-bar".underscore
    assert_equal "Foo bar", "foo_bar".humanize
    assert_equal "User", "user_id".humanize
    assert_equal "Foo Bar", "foo_bar".titleize
  end

  # camelCase from underscore text: the JSON-key shape (`host_info` →
  # `hostInfo`), the upper form, an already-camel key left alone, word
  # casing after separators, namespaces, and the loud mode guard.
  def test_string_camelize
    assert_equal "hostInfo", "host_info".camelize(:lower)
    assert_equal "HostInfo", "host_info".camelize
    assert_equal "hostInfo", "hostInfo".camelize(:lower)
    assert_equal "HostInfo", "hostInfo".camelize
    assert_equal "UserId", "user_id".camelize
    assert_equal "fOOBar", "FOO_bar".camelize(:lower)
    assert_equal "FooBar", "foo_bAR".camelize
    assert_equal "A::BC", "a/b_c".camelize
    assert_equal "FooBar", "foo__bar".camelize
    assert_equal "Foo", "_foo".camelize
    error = ""
    begin
      "x".camelize(:title)
    rescue => e
      error = e.message
    end
    assert_equal "camelize expects :upper or :lower, got :title", error
  end

  # The word forms: a word pluralized by its count (one item keeps the
  # word, other counts take the plural suffix) and a text turned into a
  # URL slug (downcased, separators folded, edges trimmed).
  def test_string_word_forms
    assert_equal "post", "post".pluralize(1)
    assert_equal "posts", "post".pluralize(2)
    assert_equal "posts", "post".pluralize(0)
    assert_equal "categories", "category".pluralize(3)
    assert_equal "boxes", "box".pluralize(2)
    assert_equal "churches", "church".pluralize(2)
    assert_equal "posts", "posts".pluralize(2)
    assert_equal "hello-world", "Hello World".parameterize
    assert_equal "a-b", "a  b".parameterize
    assert_equal "a-b", "a--b".parameterize
    assert_equal "a", "-a-!".parameterize
    assert_equal "a_b", "a_b".parameterize
    assert_equal "donald-e-knuth", "Donald E. Knuth".parameterize
  end

  # Collection helpers: `to_sentence` connectors (defaults and
  # keyword), `index_by` keying, `many?` counting, `sole` raising on
  # any other count.
  def test_collection_helpers
    assert_equal "a, b, and c", ["a", "b", "c"].to_sentence
    assert_equal "a and b", ["a", "b"].to_sentence
    assert_equal "a", ["a"].to_sentence
    assert_equal "", [].to_sentence
    assert_equal "a + b", ["a", "b"].to_sentence(two_words_connector: " + ")
    h = [1, 2].index_by { |x| x * 2 }
    assert_equal 1, h[2]
    assert_equal 2, h[4]
    assert_equal true, [1, 2].many?
    assert_equal false, [1].many?
    assert_equal 7, [7].sole
    empty_msg = ""
    begin
      [].sole
    rescue => e
      empty_msg = e.message
    end
    assert_equal "no item found", empty_msg
    multi_msg = ""
    begin
      [1, 2].sole
    rescue => e
      multi_msg = e.message
    end
    assert_equal "multiple items found", multi_msg
  end

  # Key transforms build a new hash in the other key kind.
  def test_hash_key_transforms
    h = { "a" => 1, "b" => 2 }.symbolize_keys
    assert_equal 1, h[:a]
    assert_equal 2, h[:b]
    g = { a: 1, b: 2 }.stringify_keys
    assert_equal 1, g["a"]
    assert_equal 2, g["b"]
  end

  # Deep key transforms walk nested Hashes and Arrays and answer a new
  # Hash (the bang form too — typed hashes cannot widen in place); the
  # receiver keeps its old keys.
  def test_hash_deep_transform_keys
    input = { "host_info" => { "os_name" => "ios", "networks" => [{ "ip_addr" => "1.2.3.4" }] } }
    expected = { "hostInfo" => { "osName" => "ios", "networks" => [{ "ipAddr" => "1.2.3.4" }] } }
    assert_equal expected, input.deep_transform_keys { |key| key.to_s.camelize(:lower) }
    assert_equal({ "host_info" => { "os_name" => "ios", "networks" => [{ "ip_addr" => "1.2.3.4" }] } }, input)
    assert_equal expected, input.deep_transform_keys! { |key| key.to_s.camelize(:lower) }
  end

  # Array's deep key transforms shape the Hash elements only — non-Hash
  # elements pass through — and answer a new Array (the bang form mutates
  # in place: an Array's elements don't change type when keys reshape).
  def test_array_deep_transform_keys
    input = [{ "os_name" => "ios" }, "plain", 3]
    assert_equal [{ "osName" => "ios" }, "plain", 3], input.deep_transform_keys { |key| key.to_s.camelize(:lower) }
    assert_equal [{ "os_name" => "ios" }, "plain", 3], input
    assert_equal [{ "osName" => "ios" }, "plain", 3], input.deep_transform_keys! { |key| key.to_s.camelize(:lower) }
  end

  # Query rendering: scalar pairs, a namespace, nested hashes and scalar
  # arrays, nil as a bare key, empty nested values dropped, pairs sorted
  # per level, insertion order kept under a `key[]` namespace (the
  # `Hash#to_query` shape), and a loud refusal of the unmodeled
  # Array-of-collections shape.
  def test_hash_to_query
    assert_equal "name=David&nationality=Danish", { name: "David", nationality: "Danish" }.to_query
    assert_equal "user%5Bname%5D=David", { name: "David" }.to_query("user")
    assert_equal "a=2&b=1", { b: 1, a: 2 }.to_query
    assert_equal "user%5Bname%5D=David&user%5Broles%5D%5B%5D=admin&user%5Broles%5D%5B%5D=editor",
                 { user: { name: "David", roles: ["admin", "editor"] } }.to_query
    assert_equal "a&b=x", { a: nil, b: "x" }.to_query
    assert_equal "q=a+b", { q: "a b" }.to_query
    assert_equal "c=1", { a: {}, b: [], c: 1 }.to_query
    assert_equal "tags%5B%5D%5Bb%5D=1&tags%5B%5D%5Ba%5D=2", { b: 1, a: 2 }.to_query("tags[]")
    rejected = ""
    begin
      { tags: [{ name: "x" }] }.to_query
    rescue => e
      rejected = e.message
    end
    assert_equal "to_query: an Array element cannot be a Hash or an Array", rejected
  end

  # The Object predicates: blankness across receiver shapes (nil, false,
  # empty containers, whitespace text; `0` and `:sym` stay present),
  # presence (`self` or nil), and the presence_in allow-list — values
  # match by their text, and a non-Array list is rejected at the call.
  def test_object_blank_predicates
    assert_equal true, nil.blank?
    assert_equal true, false.blank?
    assert_equal true, "".blank?
    assert_equal true, " \t\n".blank?
    assert_equal true, [].blank?
    assert_equal true, ({}.blank?)
    assert_equal false, "x".blank?
    assert_equal false, 0.blank?
    assert_equal false, (:sym).blank?
    assert_equal true, "x".present?
    assert_equal false, [].present?
    assert_equal nil, nil.presence
    assert_equal "x", "x".presence
    assert_equal "member", "member".presence_in([ "member", "admin" ])
    assert_equal :member, (:member).presence_in([ "member" ])
    assert_equal nil, "other".presence_in([ "member" ])
    guard_msg = ""
    begin
      "member".presence_in("member admin")
    rescue => e
      guard_msg = e.message
    end
    assert_equal "presence_in expects the allow-list as an Array, got String", guard_msg
  end

  # Time helpers: boundaries (inclusive nanosecond ends), clock-preserving
  # civil shifts, month clamping, the now-relative predicates, and zone
  # rendering.
  def test_time_helpers
    t = Time.local(2026, 10, 18, 13, 45, 30)
    assert_equal Time.local(2026, 10, 18, 13, 45, 0), t.beginning_of_minute
    assert_equal Time.local(2026, 10, 18, 0, 0, 0), t.beginning_of_day
    assert_equal Time.local(2026, 10, 18, 23, 59, 59).to_i, t.end_of_day.to_i
    assert_equal 999_999_999, t.end_of_day.nsec
    assert_equal Time.local(2026, 10, 18, 13, 0, 0), t.beginning_of_hour
    assert_equal Time.local(2026, 10, 18, 12, 0, 0), t.noon
    assert_equal Time.local(2026, 10, 12, 0, 0, 0), t.beginning_of_week
    assert_equal Time.local(2026, 10, 19, 0, 0, 0), t.next_week
    assert_equal Time.local(2026, 10, 5, 0, 0, 0), t.prev_week
    assert_equal Time.local(2026, 10, 1, 0, 0, 0), t.beginning_of_month
    assert_equal Time.local(2026, 10, 31, 23, 59, 59).to_i, t.end_of_month.to_i
    assert_equal Time.local(2026, 1, 1, 0, 0, 0), t.beginning_of_year
    assert_equal Time.local(2026, 10, 15, 13, 45, 30), t.days_ago(3)
    assert_equal Time.local(2026, 10, 21, 13, 45, 30), t.days_since(3)
    assert_equal Time.local(2026, 10, 19, 13, 45, 30), t.tomorrow
    assert_equal Time.local(2026, 10, 17, 13, 45, 30), t.yesterday
    assert_equal Time.local(2026, 11, 18, 13, 45, 30), t.months_since(1)
    assert_equal Time.local(2026, 9, 18, 13, 45, 30), t.months_ago(1)
    assert_equal Time.local(2026, 2, 28, 12, 0, 0), Time.local(2026, 1, 31, 12, 0, 0).months_since(1)
    assert_equal true, t.same_day?(Time.local(2026, 10, 18, 0, 30, 0))
    assert_equal false, t.same_day?(Time.local(2026, 10, 19, 0, 30, 0))
    assert_equal true, Time.now.today?
    assert_equal true, (Time.now - 60).past?
    assert_equal true, (Time.now + 60).future?
    assert_equal true, t.on_weekend?
    assert_equal false, t.on_weekday?
    assert_equal true, t.on_wday?(0)
    assert_equal 0, t.in_time_zone("UTC").utc_offset
  end

  # The stored-time codecs: a stored column text parses back (fixed
  # width, micros included; too-short text reads nil) and formats out —
  # :db as the stored column form, :iso8601 with millisecond truncation.
  def test_stored_time_conversions
    t = "2024-01-02 03:04:05.000006".to_time
    assert_equal Time.utc(2024, 1, 2, 3, 4, 5, 6), t
    assert_equal nil, "2024-01-02".to_time
    assert_equal "2024-01-02 03:04:05.000006", t.to_fs(:db)
    assert_equal "2024-01-02T03:04:05.000+00:00", t.to_fs(:iso8601)
    assert_equal "2024-01-02T03:04:05.123+00:00", "2024-01-02 03:04:05.123999".to_time.to_fs(:iso8601)
  end
end

FixtureRunner.run(ExtTest, [
  "test_integer_units_return_duration",
  "test_string_helpers",
  "test_string_camelize",
  "test_string_word_forms",
  "test_collection_helpers",
  "test_hash_key_transforms",
  "test_hash_deep_transform_keys",
  "test_array_deep_transform_keys",
  "test_hash_to_query",
  "test_object_blank_predicates",
  "test_time_helpers",
  "test_stored_time_conversions"
])
