# Per-request context for code that runs outside a controller instance: the
# dispatcher parks the request and controller here for the duration of the
# action, and readers reach them through `ActionController::Current`.
#
# @note The state is per thread (`Thread.current`): a threaded server serves
#   requests concurrently, and a single module-level slot would let one request
#   read another's controller. Each key is assigned from exactly one shape,
#   which is what lets spinel type it.
#
# @note The dispatcher sets both slots immediately before `process_action` and
#   clears them in `ensure` after it returns or raises; outside an action they
#   are nil (background jobs have no request context).
#
# @note The accessors are written as explicit `def self.` methods because that
#   is the statically resolvable form under AOT.
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
