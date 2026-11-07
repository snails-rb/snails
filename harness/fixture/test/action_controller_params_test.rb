require_relative "test_helper"
require_relative "harness_runner"

# ActionController::Params.permit (core) — the strong-parameters filter
# over the plain request-params Hash. The cases pin the shapes a
# controller filter uses: named scalars, nested hashes kept whole,
# listed keys inside hashes and arrays, and the loud refusal of a filter
# shape the function does not model.
class ParamsTest < TestBase
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

  # A scalar key survives when its value is truthy; nil, false, unknown
  # keys, and a missing key are dropped. String and Symbol sources both
  # read, and the answer keys are Symbols.
  def test_permit_keeps_named_scalars
    permitted = ActionController::Params.permit(
      { "uuid" => "u", "unknown" => "x" },
      [ :uuid ]
    )
    assert_equal({ uuid: "u" }, permitted)

    permitted = ActionController::Params.permit(
      { uuid: "u" },
      [ :uuid ]
    )
    assert_equal({ uuid: "u" }, permitted)

    permitted = ActionController::Params.permit(
      { "blank" => "", "nil_value" => nil, "false_value" => false },
      [ :blank, :nil_value, :false_value, :missing ]
    )
    assert_equal({ blank: "" }, permitted)
  end

  # A `{}` filter keeps the nested Hash as-is (JSON leaves are already
  # permitted); an Array filter keeps only the listed keys of a Hash and
  # maps each Hash element of an Array through the same list.
  def test_permit_shapes_nested_hash_and_array_filters
    permitted = ActionController::Params.permit(
      {
        "uuid" => "u",
        "host_info" => { "os" => "ios", "boot_time" => "x" },
        "network_info" => [
          { "name" => "en0", "hardware_addr" => "aa", "ip_addr" => "1.2.3.4", "extra" => "drop" },
          { "name" => "en1", "extra" => "drop" }
        ],
        "software_info" => { "os" => "ios" },
        "extra" => "drop"
      },
      [ :uuid, { host_info: {}, network_info: [ :name, :hardware_addr, :ip_addr ], software_info: {} } ]
    )
    assert_equal(
      {
        uuid: "u",
        host_info: { "os" => "ios", "boot_time" => "x" },
        network_info: [
          { "name" => "en0", "hardware_addr" => "aa", "ip_addr" => "1.2.3.4" },
          { "name" => "en1" }
        ],
        software_info: { "os" => "ios" }
      },
      permitted
    )
  end

  # Non-Hash elements of a filtered Array pass through unchanged — the
  # list filter shapes Hash elements only.
  def test_permit_passes_non_hash_array_elements
    permitted = ActionController::Params.permit(
      { "tags" => [ "alpha", { "name" => "beta", "drop" => 1 } ] },
      [ { tags: [ :name ] } ]
    )
    assert_equal({ tags: [ "alpha", { "name" => "beta" } ] }, permitted)
  end

  # The entry rejects unmodeled input instead of silently returning a
  # partial set: a non-Hash source, non-Array filters, a String filter
  # entry, a nested spec that is neither `{}` nor an Array, and a list
  # item that is not a Symbol. The filters signature stays untyped on
  # purpose: a concrete union declaration refuses the String-filter case
  # below at build time (sp_PolyArray slot), so the untyped declaration is
  # what keeps this guard contract testable.
  def test_permit_rejects_unmodeled_input
    assert_equal true, argument_error? { ActionController::Params.permit("x", []) }, "non-Hash source"
    assert_equal true, argument_error? { ActionController::Params.permit({}, "uuid") }, "non-Array filters"
    assert_equal true, argument_error? { ActionController::Params.permit({}, [ "uuid" ]) }, "String filter entry"
    assert_equal true, argument_error? { ActionController::Params.permit({}, [ { host_info: { nested: :x } } ]) }, "nested spec"
    assert_equal true, argument_error? { ActionController::Params.permit({}, [ { host_info: [ "name" ] } ]) }, "String list item"
    assert_equal({}, ActionController::Params.permit({ "uuid" => "u" }, []))
  end
end

FixtureRunner.run(ParamsTest, [
  "test_permit_keeps_named_scalars",
  "test_permit_shapes_nested_hash_and_array_filters",
  "test_permit_passes_non_hash_array_elements",
  "test_permit_rejects_unmodeled_input"
])
