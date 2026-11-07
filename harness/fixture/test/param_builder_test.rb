require_relative "test_helper"
require_relative "harness_runner"

# The request-param builder — the nesting rules, and the private boundary
# around the helpers that serve them.
class ParamBuilderTest < TestBase
  def assert_equal(expected, actual)
    raise("expected #{expected.inspect}, got #{actual.inspect}") unless expected == actual
  end

  # A query string becomes the nested params a controller reads: a hash
  # to any depth, an array under a trailing "[]", several keys in one
  # request, and a key with no "=" carried as an empty value.
  def test_query_string_becomes_nested_params
    params = ActionDispatch::ParamBuilder.from_query_string("a[b]=1&c[]=2&c[]=3&d=4")
    assert_equal({ "a" => { "b" => "1" }, "c" => ["2", "3"], "d" => "4" }, params)
  end

  # The helpers behind the builder are private: an app calling one from
  # outside gets NoMethodError rather than a quietly working answer.
  def test_the_helpers_are_not_reachable_from_outside
    keys = []
    values = []
    present = []
    message = ""
    begin
      ActionDispatch::ParamBuilder.split("a=1", keys, values, present)
    rescue Exception => e
      message = e.message
    end
    assert_equal true, message.include?("private method")
  end
end

FixtureRunner.run(ParamBuilderTest, [
  "test_query_string_becomes_nested_params",
  "test_the_helpers_are_not_reachable_from_outside"
])
