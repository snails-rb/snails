# One error boundary policy for long-lived loops: each request, job, periodic
# callback and drain is a unit whose failure must not take the loop down.
#
# Every boundary is a native `rescue Exception` that starts with
# `raise if Snails::ErrorBoundary.fatal?`, so the class list cannot drift.
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
