# Time — the date helpers. Every method delegates to
# `Snails::DateAndTime::Calculations`, which owns the civil-calendar
# arithmetic: day shifts walk the calendar (DST cannot move the clock),
# month steps clamp to the target month's last day, and rendering keeps the
# receiver's zone (the process zone, UTC, or a fixed offset).
#
# The reopen makes Time-typed parameter slots strict program-wide: a
# known-type non-Time argument is a build refusal, an unknown-type one a
# boundary TypeError before the body runs — so no method needs an in-body
# guard.
#
# Zone conversion lives in `Snails::TimeZone`, not here.
class Time
  # ---- boundaries ----

  # seconds and sub-seconds zeroed.
  #
  # @return [Time] this instant at the start of its minute
  def beginning_of_minute
    Snails::DateAndTime::Calculations.beginning_of_minute(self)
  end

  # 59.999999999 seconds, the inclusive end.
  #
  # @return [Time] this minute's inclusive end
  def end_of_minute
    Snails::DateAndTime::Calculations.end_of_minute(self)
  end

  # minutes and below zeroed.
  #
  # @return [Time] this instant at the start of its hour
  def beginning_of_hour
    Snails::DateAndTime::Calculations.beginning_of_hour(self)
  end

  # 59:59.999999999, the inclusive end.
  #
  # @return [Time] this hour's inclusive end
  def end_of_hour
    Snails::DateAndTime::Calculations.end_of_hour(self)
  end

  # midnight in the receiver's zone; a UTC receiver stays UTC and a fixed-offset
  # receiver keeps that offset.
  #
  # @return [Time] this instant's day at midnight
  def beginning_of_day
    Snails::DateAndTime::Calculations.beginning_of_day(self)
  end

  # 23:59:59.999999999, the inclusive end.
  #
  # @return [Time] this day's inclusive end
  def end_of_day
    Snails::DateAndTime::Calculations.end_of_day(self)
  end

  # 12:00:00 of the receiver's day.
  #
  # @return [Time] this instant's day at 12:00:00
  def noon
    Snails::DateAndTime::Calculations.noon(self)
  end

  # Monday, not Sunday (the calendar's week start).
  #
  # @return [Time] the week's Monday
  def beginning_of_week
    Snails::DateAndTime::Calculations.beginning_of_week(self)
  end

  # the following Sunday's inclusive end.
  #
  # @return [Time] the following Sunday's inclusive end
  def end_of_week
    Snails::DateAndTime::Calculations.end_of_week(self)
  end

  # the next week's Monday, not the receiver plus 7 days.
  #
  # @return [Time] the next week's Monday
  def next_week
    Snails::DateAndTime::Calculations.next_week(self)
  end

  # the previous week's Monday.
  #
  # @return [Time] the previous week's Monday
  def prev_week
    Snails::DateAndTime::Calculations.prev_week(self)
  end

  # the 1st at midnight.
  #
  # @return [Time] the 1st of this instant's month at midnight
  def beginning_of_month
    Snails::DateAndTime::Calculations.beginning_of_month(self)
  end

  # the last day's inclusive end (leap years included).
  #
  # @return [Time] this month's last day at its inclusive end
  def end_of_month
    Snails::DateAndTime::Calculations.end_of_month(self)
  end

  # January 1st at midnight.
  #
  # @return [Time] January 1st of this instant's year at midnight
  def beginning_of_year
    Snails::DateAndTime::Calculations.beginning_of_year(self)
  end

  # December 31st's inclusive end.
  #
  # @return [Time] December 31st's inclusive end
  def end_of_year
    Snails::DateAndTime::Calculations.end_of_year(self)
  end

  # ---- shifts ----

  # `n` civil days later at the same clock time.
  #
  # @return [Time] this instant `n` civil days later
  def days_since(n = 1)
    Snails::DateAndTime::Calculations.days_since(self, n)
  end

  # `n` civil days earlier at the same clock time.
  #
  # @return [Time] this instant `n` civil days earlier
  def days_ago(n = 1)
    Snails::DateAndTime::Calculations.days_ago(self, n)
  end

  # one civil day back.
  #
  # @return [Time] this instant one civil day back
  def yesterday
    Snails::DateAndTime::Calculations.yesterday(self)
  end

  # one civil day forward.
  #
  # @return [Time] this instant one civil day forward
  def tomorrow
    Snails::DateAndTime::Calculations.tomorrow(self)
  end

  # `n` seven-day steps forward.
  #
  # @return [Time] this instant `n` seven-day steps forward
  def weeks_since(n = 1)
    Snails::DateAndTime::Calculations.weeks_since(self, n)
  end

  # `n` seven-day steps back.
  #
  # @return [Time] this instant `n` seven-day steps back
  def weeks_ago(n = 1)
    Snails::DateAndTime::Calculations.weeks_ago(self, n)
  end

  # `n` calendar months forward, clamped to the target month's last day (Jan 31
  # + 1 month is Feb 28).
  #
  # @return [Time] this instant `n` calendar months forward
  def months_since(n = 1)
    Snails::DateAndTime::Calculations.months_since(self, n)
  end

  # the calendar-month step back.
  #
  # @return [Time] this instant `n` calendar months back
  def months_ago(n = 1)
    Snails::DateAndTime::Calculations.months_ago(self, n)
  end

  # `n` calendar years forward, clamped like a month step (Feb 29 in a leap year
  # lands on Feb 28).
  #
  # @return [Time] this instant `n` calendar years forward
  def years_since(n = 1)
    Snails::DateAndTime::Calculations.years_since(self, n)
  end

  # the calendar-year step back.
  #
  # @return [Time] this instant `n` calendar years back
  def years_ago(n = 1)
    Snails::DateAndTime::Calculations.years_ago(self, n)
  end

  # ---- predicates ----

  # both fall on the same civil day, clock time irrelevant.
  #
  # @return [Boolean] true when the two instants share a civil day
  def same_day?(other)
    Snails::DateAndTime::Calculations.same_day?(self, other)
  end

  # same civil day as now.
  #
  # @return [Boolean] true when the receiver falls on today's civil day
  def today?
    Snails::DateAndTime::Calculations.today?(self, Time.now)
  end

  # same civil day as one day back from now.
  #
  # @return [Boolean] true when the receiver falls on yesterday's civil day
  def yesterday?
    Snails::DateAndTime::Calculations.yesterday?(self, Time.now)
  end

  # same civil day as one day forward from now.
  #
  # @return [Boolean] true when the receiver falls on tomorrow's civil day
  def tomorrow?
    Snails::DateAndTime::Calculations.tomorrow?(self, Time.now)
  end

  # before now.
  #
  # @return [Boolean] true when the receiver is before now
  def past?
    Snails::DateAndTime::Calculations.past?(self, Time.now)
  end

  # after now.
  #
  # @return [Boolean] true when the receiver is after now
  def future?
    Snails::DateAndTime::Calculations.future?(self, Time.now)
  end

  # Saturday or Sunday.
  #
  # @return [Boolean] true when the receiver falls on Saturday or Sunday
  def on_weekend?
    Snails::DateAndTime::Calculations.on_weekend?(self)
  end

  # the negation of `on_weekend?`.
  #
  # @return [Boolean] true on any day but Saturday and Sunday
  def on_weekday?
    Snails::DateAndTime::Calculations.on_weekday?(self)
  end

  # the weekday number matches (0 = Sunday).
  #
  # @return [Boolean] true when the receiver falls on that weekday
  def on_wday?(wday)
    Snails::DateAndTime::Calculations.on_wday?(self, wday)
  end

  # ---- zone rendering ----

  # the same instant rendered in `zone` (a name from the runtime's zone
  # vocabulary, `Snails::TimeZone::ZONE_NAMES`, or an IANA identifier); nil
  # renders in the current zone.
  #
  # @return [Time] this instant rendered in `zone`
  def in_time_zone(zone)
    Snails::TimeZone.in_time_zone(self, zone)
  end

  # `:db` is the stored datetime column form (UTC, microsecond precision),
  # `:iso8601` the JSON spelling: millisecond truncation and the zone's offset.
  # The `:db` result is lexicographically ordered, so it sorts as text.
  #
  # @param name [Symbol] `:db` for the stored form, `:iso8601` for the JSON
  #   spelling
  # @return [String] this instant in the requested spelling
  # @raise [ArgumentError] name is neither `:db` nor `:iso8601`
  def to_fs(name)
    if name == :db
      t = utc
      format(
        "%04d-%02d-%02d %02d:%02d:%02d.%06d",
        t.year, t.mon, t.mday, t.hour, t.min, t.sec, t.usec
      )
    elsif name == :iso8601
      strftime("%Y-%m-%dT%H:%M:%S") + format(".%03d", usec / 1000) + strftime("%:z")
    else
      raise ArgumentError, "to_fs: unsupported format #{name.inspect} — :db and :iso8601 only"
    end
  end
end
