require_relative "test_helper"
require_relative "harness_runner"

# Snails::ErrorBoundary (core) — the one policy every long-lived loop's
# unit boundary shares. Pinned here: a plain application error and a
# ScriptError (NotImplementedError) are unit failures the loop survives,
# while process control (SystemExit/SignalException) and the fatal
# NoMemoryError are re-raised. Each loop spells the native `rescue` itself;
# this module owns only the class decision.
class ErrorBoundaryTest < TestBase
  def assert_equal(expected, actual, msg = nil)
    raise(msg || "expected #{expected.inspect}, got #{actual.inspect}") unless expected == actual
  end

  # A plain application error is a unit failure: the caller records it and
  # moves to the next unit.
  def test_a_standard_error_is_not_fatal
    assert_equal false, Snails::ErrorBoundary.fatal?(ArgumentError.new("bad"))
  end

  # NotImplementedError is a ScriptError, not a StandardError — it is still
  # a unit failure, not process control.
  def test_a_not_implemented_error_is_not_fatal
    assert_equal false, Snails::ErrorBoundary.fatal?(NotImplementedError.new("missing"))
  end

  # Other ScriptErrors are unit failures too: the boundary is a role, not
  # the facade-era StandardError+ScriptError class list.
  def test_another_script_error_is_not_fatal
    assert_equal false, Snails::ErrorBoundary.fatal?(ScriptError.new("script"))
  end

  # The process is exiting: every unit boundary must re-raise SystemExit.
  def test_a_system_exit_is_fatal
    assert_equal true, Snails::ErrorBoundary.fatal?(SystemExit.new("bye"))
  end

  # A signal is process control; Interrupt is a SignalException.
  def test_a_signal_exception_is_fatal
    assert_equal true, Snails::ErrorBoundary.fatal?(Interrupt.new("stop"))
  end

  # NoMemoryError leaves the VM unsafe to continue; the boundary re-raises.
  def test_a_no_memory_error_is_fatal
    assert_equal true, Snails::ErrorBoundary.fatal?(NoMemoryError.new("oom"))
  end
end

FixtureRunner.run(ErrorBoundaryTest, [
  "test_a_standard_error_is_not_fatal",
  "test_a_not_implemented_error_is_not_fatal",
  "test_another_script_error_is_not_fatal",
  "test_a_system_exit_is_fatal",
  "test_a_signal_exception_is_fatal",
  "test_a_no_memory_error_is_fatal"
])
