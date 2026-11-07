require_relative "test_helper"
require_relative "harness_runner"

# The core dispatch reports the matched controller/action/format through
# `Snails::Logger::Context` instead of logging its own line; the request
# line itself is `Tep::App#dispatch`'s (logger_test covers it).
Snails.env = "test"

# Default dispatch — the core pipeline every API-only app uses
# (snails-core/snails/main.rb). The request wiring is the part apps used to copy:
# actions read `request.headers[...]` and `request.raw_post`, and code outside
# the controller reads `ActionController::Current` during the action. The
# context is cleared when the action ends; the JSON shapes for a route miss and
# malformed params are the other half.
class MainDispatchTest < TestBase
  def assert_equal(expected, actual)
    raise("expected #{expected.inspect}, got #{actual.inspect}") unless expected == actual
  end

  def build_request(verb, path)
    req = Tep::Request.new
    req.verb = verb
    req.path = path
    req.raw_path = path
    req.remote_host = +"127.0.0.1"
    req
  end

  # The action sees the wired request/controller; dispatch clears both slots
  # when the action returns.
  def test_dispatch_exposes_current_during_the_action
    HarnessCurrentProbeController.reset
    req = build_request("GET", "/current-probe")
    req.req_headers["authorization"] = "Bearer test"
    req.req_headers["content-length"] = "42"
    req.req_headers["x-custom"] = "custom-value"
    req.raw_body = +"body-text"
    res = Tep::Response.new
    Snails::Main.dispatch(req, res)

    assert_equal 200, res.status
    wired = HarnessCurrentProbeController.seen_request
    assert_equal false, wired.nil?
    unless wired.nil?
      assert_equal "/current-probe", wired.path
      assert_equal "Bearer test", wired.headers["Authorization"]
      assert_equal "42", wired.headers["Content-Length"]
      assert_equal "custom-value", wired.headers["X-Custom"]
      assert_equal nil, wired.headers["Content-Type"]
      assert_equal false, wired.headers.has_key?("Content-Type")
      assert_equal "body-text", wired.raw_post
      assert_equal "127.0.0.1", wired.remote_ip
    end
    assert_equal true, HarnessCurrentProbeController.seen_controller.is_a?(HarnessCurrentProbeController)
    assert_equal true, HarnessCurrentProbeController.controller_was_self
    assert_equal true, ActionController::Current.request.nil?
    assert_equal true, ActionController::Current.controller.nil?
  end

  # An exception from the action still clears both slots.
  def test_dispatch_clears_current_when_the_action_raises
    raised = false
    begin
      Snails::Main.dispatch(build_request("GET", "/boom"), Tep::Response.new)
    rescue RuntimeError
      raised = true
    end
    assert_equal true, raised
    assert_equal true, ActionController::Current.request.nil?
    assert_equal true, ActionController::Current.controller.nil?
  end

  def test_dispatch_answers_json_404_for_a_miss
    res = Tep::Response.new
    Snails::Main.dispatch(build_request("GET", "/nope"), res)
    assert_equal 404, res.status
    assert_equal "application/json; charset=utf-8", res.headers["Content-Type"]
  end

  def test_dispatch_answers_json_400_for_malformed_params
    req = build_request("GET", "/up")
    req.raw_query = +"%"
    res = Tep::Response.new
    Snails::Main.dispatch(req, res)
    assert_equal 400, res.status
  end
end

FixtureRunner.run(MainDispatchTest, [
  "test_dispatch_exposes_current_during_the_action",
  "test_dispatch_clears_current_when_the_action_raises",
  "test_dispatch_answers_json_404_for_a_miss",
  "test_dispatch_answers_json_400_for_malformed_params",
])
