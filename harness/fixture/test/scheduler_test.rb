require_relative "test_helper"
require_relative "harness_runner"

# Tep::Scheduler — the fiber registry the fiber server drives, and the private
# poll-set helpers behind `tick`.
class SchedulerTest < TestBase
  def setup
    Tep::Scheduler.clear
  end

  def assert_equal(expected, actual)
    raise("expected #{expected.inspect}, got #{actual.inspect}") unless expected == actual
  end

  # A spawned fiber is tracked until it runs; clear drops it.
  def test_spawn_and_clear_track_fibers
    Tep::Scheduler.spawn_fiber(Fiber.new { 0 })
    assert_equal 1, Tep::Scheduler.alive_count
    Tep::Scheduler.clear
    assert_equal 0, Tep::Scheduler.alive_count
  end

  # The poll-set helpers sit behind `tick`; an app calling one from outside
  # is refused.
  def test_poll_helpers_are_private
    begin
      Tep::Scheduler.poll_round(0)
    rescue NoMethodError
      return
    end
    raise "expected Tep::Scheduler.poll_round to be private"
  end
end

FixtureRunner.run(SchedulerTest, [
  "test_spawn_and_clear_track_fibers",
  "test_poll_helpers_are_private"
])
