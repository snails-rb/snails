require_relative "test_helper"
require_relative "harness_runner"

# Delivery seam (core) — the registry is read per delivery, not bound at
# compile time: a registered provider receives `deliver` instead of
# deliveries growing, re-registration swaps it, the explicit capture
# collects in memory, and nothing registered is a loud miss (the next
# delivery raises — a mail that silently goes nowhere is worse). The
# stamped test-mode registration (DeliveryLog) is replaced per case here
# and asserted by delivery_log_test.
class DeliverySeamTest < TestBase
  def assert_equal(expected, actual, msg = nil)
    raise(msg || "expected #{expected.inspect}, got #{actual.inspect}") unless expected == actual
  end

  def new_message
    ActionMailer::Message.new({ to: "user@example.com", subject: "s", body: "b" })
  end

  # The explicit in-memory capture — both entry points collect and stay
  # value-shaped.
  def test_explicit_capture_collects
    ActionMailer::Base.delivery_method = ActionMailer::CaptureMethod
    before = ActionMailer::Base.deliveries.length
    message = new_message
    result = message.deliver_now
    assert_equal before + 1, ActionMailer::Base.deliveries.length
    assert_equal message, result
    result_later = message.deliver_later
    assert_equal before + 2, ActionMailer::Base.deliveries.length
    assert_equal message, result_later
  end

  # Registration: delivery routes to the provider, deliveries stays put.
  def test_registration_routes_delivery
    ActionMailer::Base.delivery_method = SeamProviderOne
    before = ActionMailer::Base.deliveries.length
    one_before = SeamProviderOne.calls.length
    message = new_message
    result = message.deliver_now
    assert_equal one_before + 1, SeamProviderOne.calls.length
    assert_equal before, ActionMailer::Base.deliveries.length
    assert_equal message, result
  end

  # Re-registration: the next call lands on the new provider.
  def test_reregistration_replaces
    ActionMailer::Base.delivery_method = SeamProviderOne
    ActionMailer::Base.delivery_method = SeamProviderTwo
    two_before = SeamProviderTwo.calls.length
    one_before = SeamProviderOne.calls.length
    message = new_message
    message.deliver_later
    assert_equal two_before + 1, SeamProviderTwo.calls.length
    assert_equal one_before, SeamProviderOne.calls.length
  end

  # Nothing registered: the read raises with the fix in the message.
  # Last in the run order — it leaves the registry cleared.
  def test_unregistered_delivery_raises
    ActionMailer::Base.delivery_method = nil
    raised = nil
    begin
      new_message.deliver_now
    rescue StandardError => e
      raised = e.message
    end
    assert_equal false, raised.nil?
    assert_equal true, raised.include?("no delivery method registered")
  end
end

module SeamProviderOne
  def self.calls
    @calls ||= []
  end

  def self.deliver(message)
    calls << message
    message
  end
end

module SeamProviderTwo
  def self.calls
    @calls ||= []
  end

  def self.deliver(message)
    calls << message
    message
  end
end

FixtureRunner.run(DeliverySeamTest, [
  "test_explicit_capture_collects",
  "test_registration_routes_delivery",
  "test_reregistration_replaces",
  "test_unregistered_delivery_raises"
])
