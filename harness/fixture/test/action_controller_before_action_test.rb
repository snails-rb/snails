require_relative "test_helper"
require_relative "harness_runner"

# before_action dialect (core) — registration (owner
# flattening, only/except lists), owner-partitioned walk, send
# dispatch (no per-controller case), filter halt, only/except gating
# through the action_name context, loud failure for a registered name
# without a method, rejection of non-Symbol registrations, and
# inherited filter methods. Ancestor auto-propagation of REGISTRATION
# is not part of the dialect — spinel never calls the inherited hook, so
# filters register on the controller that runs them.
class BeforeActionTest < TestBase
  def assert_equal(expected, actual, msg = nil)
    raise(msg || "expected #{expected.inspect}, got #{actual.inspect}") unless expected == actual
  end

  # Registration: a class-body before_action lands as
  # [owner, [symbols], only-list, except-list].
  def test_registration
    entries = ActionController::API::BEFORE_FILTERS.select { |e| e[0] == "HarnessPlainController" }
    assert_equal true, entries.any? { |e| e[1] == [:mark_ran] && e[2] == [] && e[3] == [] }
    entries = ActionController::API::BEFORE_FILTERS.select { |e| e[0] == "HarnessHaltController" }
    assert_equal true, entries.any? { |e| e[1] == [:halt_filter] && e[2] == [] && e[3] == [] }
  end

  # only/except registration: a Symbol or Array is normalized to a list.
  def test_conditional_registration
    entries = ActionController::API::BEFORE_FILTERS.select { |e| e[0] == "HarnessOnlyController" }
    only_entry = entries.find { |e| e[1] == [:mark_create] }
    assert_equal [ :create ], only_entry[2]
    assert_equal [], only_entry[3]
    entries = ActionController::API::BEFORE_FILTERS.select { |e| e[0] == "HarnessExceptController" }
    assert_equal [], entries[0][2]
    assert_equal [ :show ], entries[0][3]
  end

  # Dispatch: the registered symbol runs through core send — the
  # controller has no dispatch case.
  def test_dispatch_runs_own_filter
    c = HarnessPlainController.new
    c.run_before_filters
    assert_equal true, c.filter_ran?
    assert_equal false, c.performed?
  end

  # halt: a filter that renders stops the chain — the later filter
  # never runs.
  def test_filter_halt
    c = HarnessHaltController.new
    c.run_before_filters
    assert_equal true, c.performed?
    assert_equal false, c.filter_ran?
  end

  # Owner partition: another controller's registered filters do not
  # run on this instance.
  def test_owner_partition
    c = ApplicationController.new
    c.run_before_filters
    assert_equal false, c.performed?
  end

  # A registered name whose method does not exist fails loudly as
  # NoMethodError — silent skip is the failure class this design
  # exists to avoid.
  def test_missing_filter_method_raises
    c = HarnessMissingMethodController.new
    raised = false
    begin
      c.run_before_filters
    rescue StandardError => e
      raised = true
      assert_equal true, e.message.include?("unmapped_filter")
    end
    assert_equal true, raised
  end

  # Non-Symbol registration: a String is rejected at registration.
  def test_rejects_non_symbol_filters
    raised = false
    begin
      HarnessPlainController.before_action("not-a-symbol")
    rescue ArgumentError => e
      raised = true
      assert_equal true, e.message.include?("Symbols")
    end
    assert_equal true, raised
  end

  # only: match — with the action context set, the gated filter runs.
  def test_only_match
    c = HarnessOnlyController.new
    c.action_name = :create
    c.run_before_filters
    assert_equal true, c.create_ran?
    assert_equal true, c.all_ran?
  end

  # only: mismatch — the gated filter is skipped, the ungated one
  # runs.
  def test_only_mismatch
    c = HarnessOnlyController.new
    c.action_name = :update
    c.run_before_filters
    assert_equal false, c.create_ran?
    assert_equal true, c.all_ran?
  end

  # only: gated halt — the filter renders on create, so the later
  # filter never runs.
  def test_only_halt_skips_later_filters
    c = HarnessOnlyHaltController.new
    c.action_name = :create
    c.run_before_filters
    assert_equal true, c.performed?
    assert_equal false, c.filter_ran?
  end

  # except: match — the filter runs on an action that is not excluded.
  def test_except_match
    c = HarnessExceptController.new
    c.action_name = :index
    c.run_before_filters
    assert_equal true, c.all_ran?
  end

  # except: excluded — the filter is skipped on the excluded action.
  def test_except_excluded
    c = HarnessExceptController.new
    c.action_name = :show
    c.run_before_filters
    assert_equal false, c.all_ran?
  end

  # Conditional filter without action context — running the chain on a
  # filter that carries only/except without setting action_name raises
  # instead of silently applying it to every action (or none).
  def test_conditional_filter_without_context_raises
    c = HarnessOnlyController.new
    raised = false
    begin
      c.run_before_filters
    rescue RuntimeError => e
      raised = true
      assert_equal true, e.message.include?("action context")
    end
    assert_equal true, raised
  end

  # Inherited filter method — the child registers a name whose method
  # lives on the parent; the send dispatch reaches ancestors.
  def test_inherited_filter_method
    c = HarnessChildController.new
    c.run_before_filters
    assert_equal true, c.shared_ran?
  end
end

FixtureRunner.run(BeforeActionTest, [
  "test_registration",
  "test_conditional_registration",
  "test_dispatch_runs_own_filter",
  "test_filter_halt",
  "test_owner_partition",
  "test_missing_filter_method_raises",
  "test_rejects_non_symbol_filters",
  "test_only_match",
  "test_only_mismatch",
  "test_only_halt_skips_later_filters",
  "test_except_match",
  "test_except_excluded",
  "test_conditional_filter_without_context_raises",
  "test_inherited_filter_method"
])
