require_relative "test_helper"
require_relative "harness_runner"

# Time zone DST rules past the explicit TZif transitions — `in_time_zone`
# reads the POSIX footer through the private `rule_instant` helper.
class TimeZoneRulesTest < TestBase
  def assert_equal(expected, actual)
    raise("expected #{expected.inspect}, got #{actual.inspect}") unless expected == actual
  end

  # 2050 is past the explicit transitions in the zone file, so both offsets
  # come from the POSIX rule: EDT (-4) in July, EST (-5) in January.
  def test_posix_dst_rule_offsets
    summer = Time.utc(2050, 7, 1, 12, 0, 0).in_time_zone("America/New_York")
    winter = Time.utc(2050, 1, 1, 12, 0, 0).in_time_zone("America/New_York")
    assert_equal(-14400, summer.utc_offset)
    assert_equal(-18000, winter.utc_offset)
  end

  # The rule helper is a private instance method on the zone data; the
  # module function it replaced is gone.
  def test_rule_instant_is_not_public
    zone = Snails::TimeZone::TimeZoneData.new("UTC", [], [], 0, [])
    begin
      zone.rule_instant(2050, 3, 2, 0, 7200)
    rescue NoMethodError
      return
    end
    raise "expected TimeZoneData#rule_instant to be private"
  end
end

FixtureRunner.run(TimeZoneRulesTest, [
  "test_posix_dst_rule_offsets",
  "test_rule_instant_is_not_public"
])
