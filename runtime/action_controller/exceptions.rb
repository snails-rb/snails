# Raised by `ActionController::Params.require_key` when a required parameter
# is absent or blank, and rescued by app code as a normal path (a controller
# turns it into a 400 rather than letting a nil surface somewhere later).
# The class is real rather than a message string so a `rescue` can name it.
module ActionController
  class ParameterMissing < StandardError
    def initialize(param)
      @param = param
      super("param is missing or the value is empty or invalid: #{param}")
    end

    def param
      @param
    end
  end

  # Named by `rescue_from` clauses. No runtime path raises either: strong
  # parameters do not reject unpermitted keys, and a format an action does not
  # answer is resolved by the lowering. They exist because a rescue clause
  # evaluates its class list whenever an exception passes through it — an
  # undefined name there turns every other error the action raises into a
  # NameError that hides the real one.
  class UnpermittedParameters < StandardError
  end

  class UnknownFormat < StandardError
  end
end
