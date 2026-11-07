require_relative "test_helper"
require_relative "harness_runner"

# Action dispatch (core) — `process_action` sets the action context, runs
# the registered before-filters (a filter that responds halts the chain),
# and calls the action by name; a name with no method is a NoMethodError.
# The embedded `/up` controller rides this same path in every tree.
# The dispatch's second half is `send_action`: an action that produced
# no response answers 204 (implicit render), and a rendered response —
# from the action or from a halting filter — is never overwritten.
class HarnessDispatchController < ApplicationController
  before_action :mark_filter

  def mark_filter
    @filter_ran = true
  end

  def show
    @action_ran = true
    render(json: { "ok" => true })
  end

  def filter_ran?; !@filter_ran.nil?; end
  def action_ran?; !@action_ran.nil?; end
end

class HarnessDispatchHaltController < ApplicationController
  before_action :halt_filter

  def halt_filter
    render("denied", status: :unauthorized)
  end

  def show
    @action_ran = true
    render(json: { "ok" => true })
  end

  def action_ran?; !@action_ran.nil?; end
end

# Implicit render target — an action that produces no response.
class HarnessImplicitRenderController < ApplicationController
  def noop; end
end

# Implicit render must not overwrite a rendered response — an action
# answering a 422 with a body keeps both.
class HarnessErrorRenderController < ApplicationController
  def reject
    render("invalid", status: :unprocessable_entity)
  end
end

class ProcessActionTest < TestBase
  def assert_equal(expected, actual, msg = nil)
    raise(msg || "expected #{expected.inspect}, got #{actual.inspect}") unless expected == actual
  end

  # The preamble sets the action context, runs the filters, and reaches
  # the action.
  def test_dispatch_sets_action_context_and_runs_the_action
    c = HarnessDispatchController.new
    c.process_action(:show)
    assert_equal :show, c.action_name
    assert_equal true, c.filter_ran?
    assert_equal true, c.action_ran?
    assert_equal 200, c.status
  end

  # A filter that rendered halts the chain: the action body is skipped
  # and the implicit 204 never runs — the response stays the filter's.
  def test_a_responding_filter_halts_the_action
    c = HarnessDispatchHaltController.new
    c.process_action(:show)
    assert_equal false, c.action_ran?
    assert_equal 401, c.status
    assert_equal "denied", c.body
  end

  # A name with no method raises — a silent empty 200 is the failure
  # class this dispatch exists to avoid.
  def test_a_missing_action_method_is_loud
    c = HarnessDispatchController.new
    raised = false
    begin
      c.process_action(:nope)
    rescue StandardError => e
      raised = true
      assert_equal true, e.message.include?("nope")
    end
    assert_equal true, raised
  end

  # Implicit render: an action that produced no response answers 204
  # No Content, not the constructor's empty 200.
  def test_a_renderless_action_answers_204
    c = HarnessImplicitRenderController.new
    c.process_action(:noop)
    assert_equal 204, c.status
    assert_equal "", c.body
    assert_equal true, c.performed?
  end

  # The implicit 204 never overwrites a rendered response — the
  # action's own status and body stand.
  def test_a_rendered_action_keeps_its_response
    c = HarnessErrorRenderController.new
    c.process_action(:reject)
    assert_equal 422, c.status
    assert_equal "invalid", c.body
  end

  # The core-owned `/up` endpoint: 200 with the JSON status body.
  def test_the_health_endpoint_answers_ok
    c = Snails::HealthController.new
    c.process_action(:show)
    assert_equal 200, c.status
    assert_equal "{\"status\":\"ok\"}", c.body
  end
end

FixtureRunner.run(ProcessActionTest, [
  "test_dispatch_sets_action_context_and_runs_the_action",
  "test_a_responding_filter_halts_the_action",
  "test_a_missing_action_method_is_loud",
  "test_a_renderless_action_answers_204",
  "test_a_rendered_action_keeps_its_response",
  "test_the_health_endpoint_answers_ok",
])
