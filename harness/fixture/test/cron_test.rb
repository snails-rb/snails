require_relative "test_helper"
require_relative "harness_runner"

# Snails::Cron (core) — the five-field cron expression behind a
# recurring schedule. Pinned here: the path from text to the due occurrence
# and the next one, the day-of-month/day-of-week OR, leap-day and long-gap
# searches, aliases, and the rejections that must happen when the schedule is
# declared.
class CronTest < TestBase
  def assert_equal(expected, actual, msg = nil)
    raise(msg || "expected #{expected.inspect}, got #{actual.inspect}") unless expected == actual
  end

  def utc(year, month, day, hour, minute)
    Time.utc(year, month, day, hour, minute, 0).to_i
  end

  # a readable timestamp for the assertion messages
  def timestamp(epoch)
    Time.at(epoch).utc.to_fs(:db)[0, 19]
  end

  def rejects(expression)
    begin
      Snails::Cron.parse(expression)
    rescue ArgumentError
      true
    else
      false
    end
  end

  # A daily 06:00 schedule: before the minute the latest occurrence is
  # yesterday's, at the minute it is today's, and the next one moves to
  # tomorrow only after the minute has passed.
  def test_daily_occurrence
    cron = Snails::Cron.parse("0 6 * * *")
    assert_equal timestamp(utc(2026, 11, 17, 6, 0)), timestamp(cron.occurrence_at_or_before(utc(2026, 11, 18, 5, 0)))
    assert_equal timestamp(utc(2026, 11, 18, 6, 0)), timestamp(cron.occurrence_at_or_before(utc(2026, 11, 18, 6, 0)))
    assert_equal timestamp(utc(2026, 11, 18, 6, 0)), timestamp(cron.occurrence_at_or_before(utc(2026, 11, 18, 6, 1)))
    assert_equal timestamp(utc(2026, 11, 18, 6, 0)), timestamp(cron.occurrence_after(utc(2026, 11, 18, 5, 0)))
    assert_equal timestamp(utc(2026, 11, 19, 6, 0)), timestamp(cron.occurrence_after(utc(2026, 11, 18, 6, 0)))
  end

  # A stepped minute field advances the occurrence by the step inside the hour.
  def test_stepped_minutes
    cron = Snails::Cron.parse("*/15 * * * *")
    assert_equal timestamp(utc(2026, 11, 18, 5, 0)), timestamp(cron.occurrence_at_or_before(utc(2026, 11, 18, 5, 7)))
    assert_equal timestamp(utc(2026, 11, 18, 5, 15)), timestamp(cron.occurrence_at_or_before(utc(2026, 11, 18, 5, 15)))
    assert_equal timestamp(utc(2026, 11, 18, 5, 15)), timestamp(cron.occurrence_at_or_before(utc(2026, 11, 18, 5, 29)))
    assert_equal timestamp(utc(2026, 11, 18, 5, 30)), timestamp(cron.occurrence_after(utc(2026, 11, 18, 5, 15)))
    assert_equal timestamp(utc(2026, 11, 18, 5, 45)), timestamp(cron.occurrence_after(utc(2026, 11, 18, 5, 30)))
  end

  # Four hours a day: the last hour of the day is followed by the first of the
  # next day, not by a same-day gap.
  def test_multiple_hours
    cron = Snails::Cron.parse("0 0,6,12,18 * * *")
    assert_equal timestamp(utc(2026, 11, 18, 0, 0)), timestamp(cron.occurrence_at_or_before(utc(2026, 11, 18, 5, 0)))
    assert_equal timestamp(utc(2026, 11, 18, 6, 0)), timestamp(cron.occurrence_after(utc(2026, 11, 18, 5, 0)))
    assert_equal timestamp(utc(2026, 11, 18, 18, 0)), timestamp(cron.occurrence_at_or_before(utc(2026, 11, 18, 18, 30)))
    assert_equal timestamp(utc(2026, 11, 19, 0, 0)), timestamp(cron.occurrence_after(utc(2026, 11, 18, 18, 0)))
  end

  # A weekday range skips the weekend: Saturday and Sunday answer with Friday's
  # 22:30, and Monday morning still belongs to Friday's run until Monday 22:30.
  def test_weekday_range
    cron = Snails::Cron.parse("30 22 * * MON-FRI")
    assert_equal timestamp(utc(2026, 11, 20, 22, 30)), timestamp(cron.occurrence_at_or_before(utc(2026, 11, 21, 12, 0)))
    assert_equal timestamp(utc(2026, 11, 20, 22, 30)), timestamp(cron.occurrence_at_or_before(utc(2026, 11, 23, 8, 0)))
    assert_equal timestamp(utc(2026, 11, 23, 22, 30)), timestamp(cron.occurrence_after(utc(2026, 11, 20, 22, 30)))
    assert_equal timestamp(utc(2026, 11, 24, 22, 30)), timestamp(cron.occurrence_after(utc(2026, 11, 23, 22, 30)))
  end

  # Month names and a six-month gap resolve in both directions.
  def test_month_names
    cron = Snails::Cron.parse("0 0 1 JAN,JUL *")
    assert_equal timestamp(utc(2026, 1, 1, 0, 0)), timestamp(cron.occurrence_at_or_before(utc(2026, 3, 15, 0, 0)))
    assert_equal timestamp(utc(2026, 7, 1, 0, 0)), timestamp(cron.occurrence_after(utc(2026, 2, 1, 0, 0)))
  end

  # Both day fields restricted are ORed: every Monday and the 1st of the
  # month, whichever comes first.
  def test_day_or_weekday
    cron = Snails::Cron.parse("0 0 1 * MON")
    assert_equal timestamp(utc(2026, 11, 23, 0, 0)), timestamp(cron.occurrence_at_or_before(utc(2026, 11, 24, 12, 0)))
    assert_equal timestamp(utc(2026, 11, 30, 0, 0)), timestamp(cron.occurrence_after(utc(2026, 11, 23, 0, 0)))
    assert_equal timestamp(utc(2026, 11, 30, 0, 0)), timestamp(cron.occurrence_after(utc(2026, 11, 24, 12, 0)))
    assert_equal timestamp(utc(2026, 12, 1, 0, 0)), timestamp(cron.occurrence_after(utc(2026, 11, 30, 12, 0)))
  end

  # Feb 29 is found across the non-leap years on both sides.
  def test_leap_day
    cron = Snails::Cron.parse("0 0 29 2 *")
    assert_equal timestamp(utc(2028, 2, 29, 0, 0)), timestamp(cron.occurrence_after(utc(2026, 3, 1, 0, 0)))
    assert_equal timestamp(utc(2028, 2, 29, 0, 0)), timestamp(cron.occurrence_at_or_before(utc(2028, 3, 1, 0, 0)))
    assert_equal timestamp(utc(2032, 2, 29, 0, 0)), timestamp(cron.occurrence_after(utc(2028, 2, 29, 0, 0)))
  end

  # Aliases expand before parsing.
  def test_aliases
    assert_equal timestamp(utc(2026, 11, 18, 0, 0)), timestamp(Snails::Cron.parse("@daily").occurrence_at_or_before(utc(2026, 11, 18, 5, 0)))
    assert_equal timestamp(utc(2026, 11, 18, 10, 0)), timestamp(Snails::Cron.parse("@hourly").occurrence_at_or_before(utc(2026, 11, 18, 10, 30)))
    assert_equal timestamp(utc(2026, 11, 15, 0, 0)), timestamp(Snails::Cron.parse("@weekly").occurrence_at_or_before(utc(2026, 11, 18, 12, 0)))
    assert_equal timestamp(utc(2026, 11, 22, 0, 0)), timestamp(Snails::Cron.parse("@weekly").occurrence_after(utc(2026, 11, 15, 0, 0)))
  end

  # Names are case-insensitive and whitespace runs separate the fields.
  def test_name_and_whitespace_forms
    daily = Snails::Cron.parse("0 6 * * *")
    spaced = Snails::Cron.parse("  0\t6  * *   MON  ")
    assert_equal timestamp(utc(2026, 11, 23, 6, 0)), timestamp(spaced.occurrence_after(utc(2026, 11, 22, 12, 0)))
    assert_equal timestamp(utc(2026, 11, 17, 6, 0)), timestamp(daily.occurrence_at_or_before(utc(2026, 11, 18, 5, 0)))
    assert_equal timestamp(utc(2026, 11, 15, 0, 0)), timestamp(Snails::Cron.parse("0 0 * * sun").occurrence_at_or_before(utc(2026, 11, 18, 12, 0)))
    assert_equal timestamp(utc(2026, 11, 15, 0, 0)), timestamp(Snails::Cron.parse("0 0 * * 0").occurrence_at_or_before(utc(2026, 11, 18, 12, 0)))
  end

  # Every malformed part is rejected with its field and the whole expression.
  def test_parse_rejections
    assert_equal true, rejects("")
    assert_equal true, rejects("0 6 * *")
    assert_equal true, rejects("0 6 * * * *")
    assert_equal true, rejects("60 6 * * *")
    assert_equal true, rejects("0 24 * * *")
    assert_equal true, rejects("*/0 * * * *")
    assert_equal true, rejects("*/x * * * *")
    assert_equal true, rejects("5/10 * * * *")
    assert_equal true, rejects("0 6 * * 5-1")
    assert_equal true, rejects("0 6 * FOO *")
    assert_equal true, rejects("0 0 * * SUNDAY")
    assert_equal true, rejects("0 6 * * * Europe/Rome")
    assert_equal true, rejects("1,,2 * * * *")
    assert_equal true, rejects("0 6 * * 1,2,3,4,5,6,7,8")
    assert_equal true, rejects("@reboot")
    assert_equal true, rejects("@noon")
    assert_equal true, rejects("@weekly extra")
  end

  # A nil schedule is rejected with the class's own message, not a
  # NoMethodError from the field parser. Other wrong types stop at the typed
  # argument boundary before the body runs.
  def test_parse_rejects_nil
    nil_rejected = false
    begin
      Snails::Cron.parse(nil)
    rescue ArgumentError
      nil_rejected = true
    end
    assert_equal true, nil_rejected
  end

  # A day and month pair that never meet is rejected when the schedule is
  # declared instead of becoming a job that never runs.
  def test_impossible_day_is_rejected
    assert_equal true, rejects("0 0 31 2 *")
    assert_equal true, rejects("0 0 30 2 *")
    assert_equal true, rejects("0 0 31 4 *")
  end

  # The field helpers are private: `parse` is the only way in, and an outside
  # call is refused instead of quietly answering.
  def test_field_helpers_are_private
    begin
      Snails::Cron.field_values("0 6 * * *", "0", 0, 59, [], "minute")
    rescue NoMethodError
      return
    end
    raise "expected Snails::Cron.field_values to be private"
  end

  # The day steps are private too; an app reaches the schedule through the two
  # occurrence queries.
  def test_day_steps_are_private
    cron = Snails::Cron.parse("0 6 * * *")
    begin
      cron.day_matches?(0)
    rescue NoMethodError
      return
    end
    raise "expected Snails::Cron#day_matches? to be private"
  end
end

FixtureRunner.run(CronTest, [
  "test_daily_occurrence",
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
  "test_impossible_day_is_rejected",
  "test_field_helpers_are_private",
  "test_day_steps_are_private"
])
