require_relative "test_helper"
require_relative "harness_runner"

# Tep::Broadcast — the in-process subscriber registry, and the private local
# fan-out behind `publish`.
class BroadcastTest < TestBase
  def setup
    Tep::Broadcast.clear
  end

  def assert_equal(expected, actual)
    raise("expected #{expected.inspect}, got #{actual.inspect}") unless expected == actual
  end

  # Subscribe registers a topic/fd, the counters report it, and unsubscribe
  # drops it.
  def test_subscribe_and_unsubscribe
    index = Tep::Broadcast.subscribe("topic", -1)
    assert_equal 0, index
    assert_equal 1, Tep::Broadcast.subscriber_count
    assert_equal 1, Tep::Broadcast.subscribers_for("topic")
    Tep::Broadcast.unsubscribe(index)
    assert_equal 0, Tep::Broadcast.subscriber_count
  end

  # Publishing with no subscribers matches nothing and writes nothing.
  def test_publish_with_no_subscribers
    assert_equal 0, Tep::Broadcast.publish("topic", "payload")
  end

  # The local fan-out sits behind `publish`; an app calling it from outside
  # is refused.
  def test_local_fan_out_is_private
    begin
      Tep::Broadcast.publish_local_only("topic", "payload")
    rescue NoMethodError
      return
    end
    raise "expected Tep::Broadcast.publish_local_only to be private"
  end
end

FixtureRunner.run(BroadcastTest, [
  "test_subscribe_and_unsubscribe",
  "test_publish_with_no_subscribers",
  "test_local_fan_out_is_private"
])
