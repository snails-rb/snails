# Probe for the request-context contract: `show` records what
# `ActionController::Current` exposes while the action runs, and the test
# asserts the slots are nil again after dispatch.
class HarnessCurrentProbeController < ApplicationController
  def self.seen_request
    @seen_request
  end

  def self.seen_request=(value)
    @seen_request = value
  end

  def self.seen_controller
    @seen_controller
  end

  def self.seen_controller=(value)
    @seen_controller = value
  end

  def self.controller_was_self
    @controller_was_self
  end

  def self.controller_was_self=(value)
    @controller_was_self = value
  end

  def self.reset
    @seen_request = nil
    @seen_controller = nil
    @controller_was_self = nil
  end

  def show
    HarnessCurrentProbeController.seen_request = ActionController::Current.request
    HarnessCurrentProbeController.seen_controller = ActionController::Current.controller
    HarnessCurrentProbeController.controller_was_self = ActionController::Current.controller.equal?(self)
    render(json: { "ok" => true })
  end
end
