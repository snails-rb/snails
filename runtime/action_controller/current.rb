# Per-request context for code outside a controller instance: the dispatcher
# stores the request and controller here for the action's duration.
# Per-thread (`Thread.current`), so concurrent requests cannot read each
# other's controller; slots are set before the action and cleared in `ensure`.
# Explicit `def self.` methods are the form AOT resolves statically.
module ActionController
  class API
    # the request object the dispatcher wires before the action runs.
    #
    # @return [ActionDispatch::Request, nil] the current request, or nil
    #   outside a dispatch
    # @param value [ActionDispatch::Request, nil] the request to park
    attr_accessor :request
  end

  # Per-request values for code that has no controller instance to read them
  # from.
  #
  # @note The dispatcher writes both slots immediately before the action and
  #   clears them when it returns or raises.
  module Current
    # the request parked for the current thread during the current action.
    #
    # @return [ActionDispatch::Request, nil] the current request, or nil
    #   outside an action
    def self.request
      Thread.current[:ac_current_request]
    end

    # park the request for the current thread.
    #
    # @param value [ActionDispatch::Request, nil] the request to park
    # @return [ActionDispatch::Request, nil] the parked request
    def self.request=(value)
      Thread.current[:ac_current_request] = value
    end

    # the controller parked for the current thread during the current action.
    #
    # @return [ActionController::API, nil] the current controller, or nil
    #   outside an action
    def self.controller
      Thread.current[:ac_current_controller]
    end

    # park the controller for the current thread.
    #
    # @param value [ActionController::API, nil] the controller to park
    # @return [ActionController::API, nil] the parked controller
    def self.controller=(value)
      Thread.current[:ac_current_controller] = value
    end
  end
end
