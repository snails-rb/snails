require_relative "test_helper"
require_relative "harness_runner"

# Snails::Cron (core) — the five-field parser behind a recurring schedule.
# Pinned here: the path from text to the covering bucket and the next one,
# the canon's day-of-month/day-of-week OR, leap-day and long-gap scans,
# aliases, and the registration-time rejections.
class CronTest < TestBase
  def assert_equal(expected, actual, msg = nil)
    raise(msg || "expected #{expected.inspect}, got #{actual.inspect}") unless expected == actual
  end

  def utc(year, month, day, hour, minute)
    Time.utc(year, month, day, hour, minute, 0).to_i
  end

  # a comparable, readable stamp for the assertion messages
  def stamp(epoch)
    Time.at(epoch).utc.to_fs(:db)[0, 19]
  end

  def rejects(spec)
    begin
      Snails::Cron.parse(spec)
    rescue ArgumentError
      true
    else
      false
    end
  end

  # A daily 06:00 spec covers yesterday's 06:00 before the minute, today's
  # from the minute on, and moves to tomorrow only after it.
  def test_daily_bucket
    cron = Snails::Cron.parse("0 6 * * *")
    assert_equal stamp(utc(2026, 11, 17, 6, 0)), stamp(cron.bucket_start_at(utc(2026, 11, 18, 5, 0)))
    assert_equal stamp(utc(2026, 11, 18, 6, 0)), stamp(cron.bucket_start_at(utc(2026, 11, 18, 6, 0)))
    assert_equal stamp(utc(2026, 11, 18, 6, 0)), stamp(cron.bucket_start_at(utc(2026, 11, 18, 6, 1)))
    assert_equal stamp(utc(2026, 11, 18, 6, 0)), stamp(cron.next_bucket_start_at(utc(2026, 11, 18, 5, 0)))
    assert_equal stamp(utc(2026, 11, 19, 6, 0)), stamp(cron.next_bucket_start_at(utc(2026, 11, 18, 6, 0)))
  end

  # A stepped minute field advances bucket starts by the step inside the hour.
  def test_stepped_minutes
    cron = Snails::Cron.parse("*/15 * * * *")
    assert_equal stamp(utc(2026, 11, 18, 5, 0)), stamp(cron.bucket_start_at(utc(2026, 11, 18, 5, 7)))
    assert_equal stamp(utc(2026, 11, 18, 5, 15)), stamp(cron.bucket_start_at(utc(2026, 11, 18, 5, 15)))
    assert_equal stamp(utc(2026, 11, 18, 5, 15)), stamp(cron.bucket_start_at(utc(2026, 11, 18, 5, 29)))
    assert_equal stamp(utc(2026, 11, 18, 5, 30)), stamp(cron.next_bucket_start_at(utc(2026, 11, 18, 5, 15)))
    assert_equal stamp(utc(2026, 11, 18, 5, 45)), stamp(cron.next_bucket_start_at(utc(2026, 11, 18, 5, 30)))
  end

  # Four hours a day: the last hour of the day is followed by the first of the
  # next day, not by a same-day gap.
  def test_multiple_hours
    cron = Snails::Cron.parse("0 0,6,12,18 * * *")
    assert_equal stamp(utc(2026, 11, 18, 0, 0)), stamp(cron.bucket_start_at(utc(2026, 11, 18, 5, 0)))
    assert_equal stamp(utc(2026, 11, 18, 6, 0)), stamp(cron.next_bucket_start_at(utc(2026, 11, 18, 5, 0)))
    assert_equal stamp(utc(2026, 11, 18, 18, 0)), stamp(cron.bucket_start_at(utc(2026, 11, 18, 18, 30)))
    assert_equal stamp(utc(2026, 11, 19, 0, 0)), stamp(cron.next_bucket_start_at(utc(2026, 11, 18, 18, 0)))
  end

  # A weekday range skips the weekend: Saturday and Sunday belong to Friday's
  # bucket, and Monday morning belongs to Friday's 22:30 until Monday 22:30.
  def test_weekday_range
    cron = Snails::Cron.parse("30 22 * * MON-FRI")
    assert_equal stamp(utc(2026, 11, 20, 22, 30)), stamp(cron.bucket_start_at(utc(2026, 11, 21, 12, 0)))
    assert_equal stamp(utc(2026, 11, 20, 22, 30)), stamp(cron.bucket_start_at(utc(2026, 11, 23, 8, 0)))
    assert_equal stamp(utc(2026, 11, 23, 22, 30)), stamp(cron.next_bucket_start_at(utc(2026, 11, 20, 22, 30)))
    assert_equal stamp(utc(2026, 11, 24, 22, 30)), stamp(cron.next_bucket_start_at(utc(2026, 11, 23, 22, 30)))
  end

  # Month names and a six-month gap resolve in both directions.
  def test_month_names
    cron = Snails::Cron.parse("0 0 1 JAN,JUL *")
    assert_equal stamp(utc(2026, 1, 1, 0, 0)), stamp(cron.bucket_start_at(utc(2026, 3, 15, 0, 0)))
    assert_equal stamp(utc(2026, 7, 1, 0, 0)), stamp(cron.next_bucket_start_at(utc(2026, 2, 1, 0, 0)))
  end

  # Both day fields restricted are ORed: every Monday and the 1st of the
  # month, whichever comes first.
  def test_day_or_weekday
    cron = Snails::Cron.parse("0 0 1 * MON")
    assert_equal stamp(utc(2026, 11, 23, 0, 0)), stamp(cron.bucket_start_at(utc(2026, 11, 24, 12, 0)))
    assert_equal stamp(utc(2026, 11, 30, 0, 0)), stamp(cron.next_bucket_start_at(utc(2026, 11, 23, 0, 0)))
    assert_equal stamp(utc(2026, 11, 30, 0, 0)), stamp(cron.next_bucket_start_at(utc(2026, 11, 24, 12, 0)))
    assert_equal stamp(utc(2026, 12, 1, 0, 0)), stamp(cron.next_bucket_start_at(utc(2026, 11, 30, 12, 0)))
  end

  # Feb 29 is found across the non-leap years on both sides.
  def test_leap_day
    cron = Snails::Cron.parse("0 0 29 2 *")
    assert_equal stamp(utc(2028, 2, 29, 0, 0)), stamp(cron.next_bucket_start_at(utc(2026, 3, 1, 0, 0)))
    assert_equal stamp(utc(2028, 2, 29, 0, 0)), stamp(cron.bucket_start_at(utc(2028, 3, 1, 0, 0)))
    assert_equal stamp(utc(2032, 2, 29, 0, 0)), stamp(cron.next_bucket_start_at(utc(2028, 2, 29, 0, 0)))
  end

  # Aliases expand before parsing; @reboot has no calendar schedule.
  def test_aliases
    assert_equal stamp(utc(2026, 11, 18, 0, 0)), stamp(Snails::Cron.parse("@daily").bucket_start_at(utc(2026, 11, 18, 5, 0)))
    assert_equal stamp(utc(2026, 11, 18, 12, 0)), stamp(Snails::Cron.parse("@noon").next_bucket_start_at(utc(2026, 11, 18, 5, 0)))
    assert_equal stamp(utc(2026, 11, 18, 10, 0)), stamp(Snails::Cron.parse("@hourly").bucket_start_at(utc(2026, 11, 18, 10, 30)))
    assert_equal stamp(utc(2026, 11, 15, 0, 0)), stamp(Snails::Cron.parse("@weekly").bucket_start_at(utc(2026, 11, 18, 12, 0)))
    assert_equal stamp(utc(2026, 11, 22, 0, 0)), stamp(Snails::Cron.parse("@weekly").next_bucket_start_at(utc(2026, 11, 15, 0, 0)))
  end

  # Names are case-insensitive and whitespace runs separate the fields.
  def test_name_and_whitespace_forms
    daily = Snails::Cron.parse("0 6 * * *")
    spaced = Snails::Cron.parse("  0\t6  * *   MON  ")
    assert_equal stamp(utc(2026, 11, 23, 6, 0)), stamp(spaced.next_bucket_start_at(utc(2026, 11, 22, 12, 0)))
    assert_equal stamp(utc(2026, 11, 17, 6, 0)), stamp(daily.bucket_start_at(utc(2026, 11, 18, 5, 0)))
    assert_equal stamp(utc(2026, 11, 15, 0, 0)), stamp(Snails::Cron.parse("0 0 * * sun").bucket_start_at(utc(2026, 11, 18, 12, 0)))
    assert_equal stamp(utc(2026, 11, 15, 0, 0)), stamp(Snails::Cron.parse("0 0 * * 0").bucket_start_at(utc(2026, 11, 18, 12, 0)))
  end

  # Registration is the rejecting point: every malformed part names its field
  # and the whole expression.
  def test_parse_rejections
    assert_equal true, rejects("")
    assert_equal true, rejects("0 6 * *")
    assert_equal true, rejects("0 6 * * * *")
    assert_equal true, rejects("60 6 * * *")
    assert_equal true, rejects("0 24 * * *")
    assert_equal true, rejects("*/0 * * * *")
    assert_equal true, rejects("*/x * * * *")
    assert_equal true, rejects("0 6 * * 5-1")
    assert_equal true, rejects("0 6 * FOO *")
    assert_equal true, rejects("0 0 * * SUNDAY")
    assert_equal true, rejects("0 6 * * * Europe/Rome")
    assert_equal true, rejects("1,,2 * * * *")
    assert_equal true, rejects("0 6 * * 1,2,3,4,5,6,7,8")
    assert_equal true, rejects("@reboot")
    assert_equal true, rejects("@weekly extra")
  end

  # A nil schedule is the missing-keyword case: it fails with the class's own
  # message, not a NoMethodError from the field parser. Other wrong types stop
  # at the typed argument boundary before the body runs.
  def test_parse_rejects_nil
    nil_rejected = false
    begin
      Snails::Cron.parse(nil)
    rescue ArgumentError
      nil_rejected = true
    end
    assert_equal true, nil_rejected
  end

  # A day and month pair that never meet is rejected at registration instead
  # of becoming a beat that is never due.
  def test_impossible_day_is_rejected
    assert_equal true, rejects("0 0 31 2 *")
    assert_equal true, rejects("0 0 30 2 *")
    assert_equal true, rejects("0 0 31 4 *")
  end
end

FixtureRunner.run(CronTest, [
  "test_daily_bucket",
  "test_stepped_minutes",
  "test_multiple_hours",
  "test_weekday_range",
  "test_month_names",
  "test_day_or_weekday",
  "test_leap_day",
  "test_aliases",
  "test_name_and_whitespace_forms",
  "test_parse_rejections",
  "test_parse_rejects_nil",
  "test_impossible_day_is_rejected"
])
