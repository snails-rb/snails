require_relative "test_helper"
require_relative "harness_runner"

# render (core) — two mutually exclusive bodies on one entry
# point: the positional body (already-rendered text, unchanged from
# before) and the `json:` keyword (a payload the controller encodes,
# answering the JSON content type). Exactly one must be given — neither
# and both are loud ArgumentErrors rather than a guessed body — and
# `json: nil` still renders, encoding to `null`.
class RenderTest < TestBase
  def assert_equal(expected, actual)
    raise("expected #{expected.inspect}, got #{actual.inspect}") unless expected == actual
  end

  def test_positional_body_unchanged
    c = ApplicationController.new
    c.render("denied")
    assert_equal "denied", c.body
    assert_equal 200, c.status
    assert_equal "text/html; charset=utf-8", c.content_type
    assert_equal true, c.performed?
    assert_equal nil, c.location
  end

  def test_positional_body_with_status_and_explicit_content_type
    c = ApplicationController.new
    c.render("gone", status: :not_found, content_type: "text/plain")
    assert_equal "gone", c.body
    assert_equal 404, c.status
    assert_equal "text/plain", c.content_type
  end

  def test_json_encodes_payload_and_sets_json_content_type
    c = ApplicationController.new
    c.render(json: { "error" => "bad" })
    assert_equal '{"error":"bad"}', c.body
    assert_equal "application/json; charset=utf-8", c.content_type
    assert_equal 200, c.status
    assert_equal true, c.performed?
  end

  def test_json_takes_symbol_keys_and_nested_values
    c = ApplicationController.new
    c.render(json: { errors: ["a", "b"], count: 2 })
    assert_equal '{"errors":["a","b"],"count":2}', c.body
    assert_equal "application/json; charset=utf-8", c.content_type
  end

  def test_json_string_payload_is_encoded_not_passed_through
    # A String is a payload like any other — encoding it is the point
    # of the keyword. Pre-encoded JSON goes in the positional body.
    c = ApplicationController.new
    c.render(json: "hi")
    assert_equal '"hi"', c.body
    assert_equal "application/json; charset=utf-8", c.content_type
  end

  def test_json_nil_renders_null
    # nil is a legal payload (an endpoint with nothing to answer); the
    # JSON_NOT_GIVEN sentinel is what tells it apart from an omitted
    # keyword, which raises instead.
    c = ApplicationController.new
    c.render(json: nil)
    assert_equal "null", c.body
    assert_equal "application/json; charset=utf-8", c.content_type
    assert_equal 200, c.status
  end

  def test_json_honors_status_and_location
    c = ApplicationController.new
    c.render(json: { id: 1 }, status: :created, location: "/posts/1")
    assert_equal '{"id":1}', c.body
    assert_equal 201, c.status
    assert_equal "/posts/1", c.location
    assert_equal "application/json; charset=utf-8", c.content_type
  end

  def test_json_explicit_content_type_wins
    c = ApplicationController.new
    c.render(json: { ok: true }, content_type: "application/problem+json")
    assert_equal "application/problem+json", c.content_type
  end

  # A Time in the payload renders as its JSON spelling — millisecond
  # truncation and the zone's offset — so a hydrated time column goes
  # into the payload as Time, with no controller-side formatter.
  def test_json_renders_time_as_iso8601
    c = ApplicationController.new
    c.render(json: { "created_at" => Time.utc(2024, 1, 2, 3, 4, 5, 123456), "absent" => nil })
    assert_equal '{"created_at":"2024-01-02T03:04:05.123+00:00","absent":null}', c.body
  end

  def test_neither_body_nor_json_raises
    c = ApplicationController.new
    message = nil
    begin
      c.render
    rescue ArgumentError => e
      message = e.message
    end
    assert_equal "render takes a body or json:", message
  end

  # A literal integer status is accepted beside the symbol form — the
  # spelling an existing action already uses (`status: 201`).
  def test_integer_status_is_accepted
    c = ApplicationController.new
    c.render(json: { id: 1 }, status: 201)
    assert_equal '{"id":1}', c.body
    assert_equal 201, c.status
  end

  # An integer outside 100..599 is not an HTTP status, so the raise
  # states the accepted range instead of sending an unreadable code.
  def test_out_of_range_integer_status_raises
    c = ApplicationController.new
    message = nil
    begin
      c.render(json: { id: 1 }, status: 2000)
    rescue RuntimeError => e
      message = e.message
    end
    assert_equal "Invalid HTTP status: 2000 — pass an integer in 100..599 or a symbol like :ok", message
  end

  # A misspelled symbol names both accepted forms in the raise, so the
  # line can be fixed from the message alone.
  def test_unknown_symbol_status_raises_with_both_forms
    c = ApplicationController.new
    message = nil
    begin
      c.render(json: { id: 1 }, status: :okay)
    rescue RuntimeError => e
      message = e.message
    end
    assert_equal "Invalid HTTP status: okay — pass a symbol like :ok or an integer in 100..599", message
  end

  def test_body_and_json_together_raises
    c = ApplicationController.new
    message = nil
    begin
      c.render("text", json: { "a" => 1 })
    rescue ArgumentError => e
      message = e.message
    end
    assert_equal "render takes a body or json:, not both", message
  end
end

FixtureRunner.run(RenderTest, [
  "test_positional_body_unchanged",
  "test_positional_body_with_status_and_explicit_content_type",
  "test_json_encodes_payload_and_sets_json_content_type",
  "test_json_takes_symbol_keys_and_nested_values",
  "test_json_string_payload_is_encoded_not_passed_through",
  "test_json_nil_renders_null",
  "test_json_honors_status_and_location",
  "test_json_explicit_content_type_wins",
  "test_json_renders_time_as_iso8601",
  "test_neither_body_nor_json_raises",
  "test_integer_status_is_accepted",
  "test_out_of_range_integer_status_raises",
  "test_unknown_symbol_status_raises_with_both_forms",
  "test_body_and_json_together_raises",
])
