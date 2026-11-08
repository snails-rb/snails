# The framework's one error boundary policy for long-lived loops. A server
# request, a job body, a periodic callback, and a drain are each
# one unit; one unit's failure must not take the loop (or the process)
# with it. This module owns the one decision every unit boundary shares —
# which exceptions leave the boundary instead of becoming a unit failure
# — so the loops cannot drift into different class lists.
#
# A boundary is a native `rescue Exception` at the unit's edge, with
# `raise if Snails::ErrorBoundary.fatal?(failure)` as its first line.
# Ruby's failure channel stays an exception; no runner returns a failure
# value for the caller to check.
module Snails
  module ErrorBoundary
    # true when the exception means the process is stopping (`SystemExit`,
    # `SignalException` — `Interrupt` included) or the VM is unsafe to continue
    # (`NoMemoryError`). Those must escape every unit boundary; every other
    # `Exception` is a unit failure the loop survives (for example
    # `NotImplementedError`, a `ScriptError`).
    #
    # @param failure [Exception] the exception a unit boundary rescued
    # @return [Boolean] true when the boundary must re-raise
    def self.fatal?(failure)
      failure.is_a?(SystemExit) ||
        failure.is_a?(SignalException) ||
        failure.is_a?(NoMemoryError)
    end
  end
end
