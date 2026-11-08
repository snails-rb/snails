# Civil-calendar date arithmetic — day shifts, period boundaries, and the
# predicates over them. A day shift rebuilds the civil date (DST cannot move
# the clock), and month arithmetic clamps to the target month's last day.
# The rebuilt value keeps the receiver's zone: a process-zone Time follows
# that zone's DST rule, while a UTC or fixed-offset Time keeps its offset.
module Snails
  module DateAndTime
    module Calculations
      # the civil date as a day count from 1970-01-01, derived from the calendar
      # fields rather than an instant's epoch seconds.
      #
      # @param y [Integer] the civil year
      # @param m [Integer] the civil month (1–12)
      # @param d [Integer] the civil day
      # @return [Integer] days since the epoch
      # @example
      #   Snails::DateAndTime::Calculations.civil_days(2024, 1, 2)  # => 19724
      def self.civil_days(y, m, d)
        yy = m <= 2 ? y - 1 : y
        era = yy / 400
        yoe = yy - era * 400
        doy = (153 * (m > 2 ? m - 3 : m + 9) + 2) / 5 + d - 1
        doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        era * 146097 + doe - 719468
      end

      # the number of days in the civil month.
      #
      # @param y [Integer] the civil year
      # @param m [Integer] the civil month (1–12)
      # @return [Integer] 28 to 31
      # @example
      #   Snails::DateAndTime::Calculations.days_in_month(2024, 2)  # => 29
      def self.days_in_month(y, m)
        m == 12 ? civil_days(y + 1, 1, 1) - civil_days(y, 12, 1) : civil_days(y, m + 1, 1) - civil_days(y, m, 1)
      end

      # `n` civil days later at the same wall-clock time; the day count walks
      # the calendar, so a DST transition cannot move the clock.
      #
      # @param t [Time] the instant to shift
      # @param n [Integer] the day count (default 1)
      # @return [Time] the shifted instant
      # @example
      #   Snails::DateAndTime::Calculations.days_since(Time.utc(2024, 1, 2, 3, 4, 5))
      #   # => 2024-01-03 03:04:05 UTC
      def self.days_since(t, n = 1)
        local_on(t, civil_days(t.year, t.month, t.day) + n, t.hour, t.min, t.sec, t.nsec)
      end

      # `n` civil days earlier at the same wall-clock time; the negative twin of
      # `days_since`.
      #
      # @param t [Time] the instant to shift
      # @param n [Integer] the day count (default 1)
      # @return [Time] the shifted instant
      # @example
      #   Snails::DateAndTime::Calculations.days_ago(Time.utc(2024, 1, 2, 3, 4, 5))
      #   # => 2024-01-01 03:04:05 UTC
      def self.days_ago(t, n = 1)
        days_since(t, -n)
      end

      # one civil day earlier at the same wall-clock time.
      #
      # @param t [Time] the instant to shift
      # @return [Time] the previous day at the same clock time
      # @example
      #   Snails::DateAndTime::Calculations.yesterday(Time.utc(2024, 1, 2, 3, 4, 5))
      #   # => 2024-01-01 03:04:05 UTC
      def self.yesterday(t)
        days_since(t, -1)
      end

      # one civil day later at the same wall-clock time.
      #
      # @param t [Time] the instant to shift
      # @return [Time] the next day at the same clock time
      # @example
      #   Snails::DateAndTime::Calculations.tomorrow(Time.utc(2024, 1, 2, 3, 4, 5))
      #   # => 2024-01-03 03:04:05 UTC
      def self.tomorrow(t)
        days_since(t, 1)
      end

      # `n` weeks (7 days each) later at the same wall-clock time.
      #
      # @param t [Time] the instant to shift
      # @param n [Integer] the week count (default 1)
      # @return [Time] the shifted instant
      # @example
      #   Snails::DateAndTime::Calculations.weeks_since(Time.utc(2024, 1, 2, 3, 4, 5), 2)
      #   # => 2024-01-16 03:04:05 UTC
      def self.weeks_since(t, n = 1)
        days_since(t, 7 * n)
      end

      # `n` weeks (7 days each) earlier at the same wall-clock time.
      #
      # @param t [Time] the instant to shift
      # @param n [Integer] the week count (default 1)
      # @return [Time] the shifted instant
      # @example
      #   Snails::DateAndTime::Calculations.weeks_ago(Time.utc(2024, 1, 2, 3, 4, 5), 2)
      #   # => 2023-12-19 03:04:05 UTC
      def self.weeks_ago(t, n = 1)
        days_since(t, -7 * n)
      end

      # `n` calendar months later at the same wall-clock time; the day clamps to
      # the target month's last day (Jan 31 + 1 month is Feb 29 in a leap year).
      #
      # @param t [Time] the instant to shift
      # @param n [Integer] the month count (default 1)
      # @return [Time] the shifted instant
      # @example
      #   Snails::DateAndTime::Calculations.months_since(Time.utc(2024, 1, 31, 3, 4, 5))
      #   # => 2024-02-29 03:04:05 UTC
      def self.months_since(t, n = 1)
        total = t.year * 12 + t.month - 1 + n
        y = total / 12
        m = total % 12 + 1
        last = days_in_month(y, m)
        local_time(t, y, m, t.day > last ? last : t.day, t.hour, t.min, t.sec, t.nsec)
      end

      # `n` calendar months earlier at the same wall-clock time; the negative
      # twin of `months_since`.
      #
      # @param t [Time] the instant to shift
      # @param n [Integer] the month count (default 1)
      # @return [Time] the shifted instant
      # @example
      #   Snails::DateAndTime::Calculations.months_ago(Time.utc(2024, 3, 31, 3, 4, 5))
      #   # => 2024-02-29 03:04:05 UTC
      def self.months_ago(t, n = 1)
        months_since(t, -n)
      end

      # `n` calendar years (12 months each) later at the same wall-clock time; a
      # leap day clamps to the target month's last day.
      #
      # @param t [Time] the instant to shift
      # @param n [Integer] the year count (default 1)
      # @return [Time] the shifted instant
      # @example
      #   Snails::DateAndTime::Calculations.years_since(Time.utc(2024, 2, 29, 3, 4, 5))
      #   # => 2025-02-28 03:04:05 UTC
      def self.years_since(t, n = 1)
        months_since(t, 12 * n)
      end

      # `n` calendar years (12 months each) earlier at the same wall-clock time;
      # the negative twin of `years_since`.
      #
      # @param t [Time] the instant to shift
      # @param n [Integer] the year count (default 1)
      # @return [Time] the shifted instant
      # @example
      #   Snails::DateAndTime::Calculations.years_ago(Time.utc(2024, 3, 31, 3, 4, 5))
      #   # => 2023-03-31 03:04:05 UTC
      def self.years_ago(t, n = 1)
        months_since(t, -12 * n)
      end

      # the start of `t`'s minute: seconds and smaller fields are zeroed.
      #
      # @param t [Time] the instant whose minute is measured
      # @return [Time] the minute's start
      # @example
      #   Snails::DateAndTime::Calculations.beginning_of_minute(Time.utc(2024, 1, 2, 3, 4, 5))
      #   # => 2024-01-02 03:04:00 UTC
      def self.beginning_of_minute(t)
        local_time(t, t.year, t.month, t.day, t.hour, t.min, 0, 0)
      end

      # the inclusive end of `t`'s minute, on the last nanosecond
      # (…:59.999999999).
      #
      # @param t [Time] the instant whose minute is measured
      # @return [Time] the minute's inclusive end
      # @example
      #   Snails::DateAndTime::Calculations.end_of_minute(Time.utc(2024, 1, 2, 3, 4, 5))
      #   # => 2024-01-02 03:04:59.999999999 UTC
      def self.end_of_minute(t)
        local_time(t, t.year, t.month, t.day, t.hour, t.min, 59, 999_999_999)
      end

      # the start of `t`'s hour: minutes and smaller fields are zeroed.
      #
      # @param t [Time] the instant whose hour is measured
      # @return [Time] the hour's start
      # @example
      #   Snails::DateAndTime::Calculations.beginning_of_hour(Time.utc(2024, 1, 2, 3, 4, 5))
      #   # => 2024-01-02 03:00:00 UTC
      def self.beginning_of_hour(t)
        local_time(t, t.year, t.month, t.day, t.hour, 0, 0, 0)
      end

      # the inclusive end of `t`'s hour, on the last nanosecond
      # (…:59.999999999).
      #
      # @param t [Time] the instant whose hour is measured
      # @return [Time] the hour's inclusive end
      # @example
      #   Snails::DateAndTime::Calculations.end_of_hour(Time.utc(2024, 1, 2, 3, 4, 5))
      #   # => 2024-01-02 03:59:59.999999999 UTC
      def self.end_of_hour(t)
        local_time(t, t.year, t.month, t.day, t.hour, 59, 59, 999_999_999)
      end

      # midnight at the start of `t`'s day.
      #
      # @param t [Time] the instant whose day is measured
      # @return [Time] the day's midnight
      # @example
      #   Snails::DateAndTime::Calculations.beginning_of_day(Time.utc(2024, 1, 2, 3, 4, 5))
      #   # => 2024-01-02 00:00:00 UTC
      def self.beginning_of_day(t)
        local_time(t, t.year, t.month, t.day, 0, 0, 0, 0)
      end

      # the inclusive end of `t`'s day, on the last nanosecond
      # (23:59:59.999999999).
      #
      # @param t [Time] the instant whose day is measured
      # @return [Time] the day's inclusive end
      # @example
      #   Snails::DateAndTime::Calculations.end_of_day(Time.utc(2024, 1, 2, 3, 4, 5))
      #   # => 2024-01-02 23:59:59.999999999 UTC
      def self.end_of_day(t)
        local_time(t, t.year, t.month, t.day, 23, 59, 59, 999_999_999)
      end

      # 12:00:00 of `t`'s day.
      #
      # @param t [Time] the instant whose day is measured
      # @return [Time] the day's midpoint
      # @example
      #   Snails::DateAndTime::Calculations.noon(Time.utc(2024, 1, 2, 3, 4, 5))
      #   # => 2024-01-02 12:00:00 UTC
      def self.noon(t)
        local_time(t, t.year, t.month, t.day, 12, 0, 0, 0)
      end

      # Monday 00:00 of the week containing `t`; weeks start on Monday.
      #
      # @param t [Time] the instant whose week is measured
      # @return [Time] the week's Monday at midnight
      # @example
      #   Snails::DateAndTime::Calculations.beginning_of_week(Time.utc(2024, 1, 3, 3, 4, 5))
      #   # => 2024-01-01 00:00:00 UTC
      def self.beginning_of_week(t)
        local_on(t, civil_days(t.year, t.month, t.day) - (t.wday + 6) % 7, 0, 0, 0, 0)
      end

      # Sunday 23:59:59.999999999 of the week containing `t`.
      #
      # @param t [Time] the instant whose week is measured
      # @return [Time] the week's Sunday at its inclusive end
      # @example
      #   Snails::DateAndTime::Calculations.end_of_week(Time.utc(2024, 1, 3, 3, 4, 5))
      #   # => 2024-01-07 23:59:59.999999999 UTC
      def self.end_of_week(t)
        end_of_day(days_since(beginning_of_week(t), 6))
      end

      # Monday 00:00 of the week after `t`'s week.
      #
      # @param t [Time] the instant whose week is measured
      # @return [Time] the following week's Monday at midnight
      # @example
      #   Snails::DateAndTime::Calculations.next_week(Time.utc(2024, 1, 3, 3, 4, 5))
      #   # => 2024-01-08 00:00:00 UTC
      def self.next_week(t)
        beginning_of_week(days_since(t, 7))
      end

      # Monday 00:00 of the week before `t`'s week.
      #
      # @param t [Time] the instant whose week is measured
      # @return [Time] the previous week's Monday at midnight
      # @example
      #   Snails::DateAndTime::Calculations.prev_week(Time.utc(2024, 1, 3, 3, 4, 5))
      #   # => 2023-12-25 00:00:00 UTC
      def self.prev_week(t)
        beginning_of_week(days_since(t, -7))
      end

      # the 1st at 00:00 of `t`'s month.
      #
      # @param t [Time] the instant whose month is measured
      # @return [Time] the month's first day at midnight
      # @example
      #   Snails::DateAndTime::Calculations.beginning_of_month(Time.utc(2024, 1, 2, 3, 4, 5))
      #   # => 2024-01-01 00:00:00 UTC
      def self.beginning_of_month(t)
        local_time(t, t.year, t.month, 1, 0, 0, 0, 0)
      end

      # the last day of `t`'s month at its inclusive end (leap years included).
      #
      # @param t [Time] the instant whose month is measured
      # @return [Time] the month's last day at its inclusive end
      # @example
      #   Snails::DateAndTime::Calculations.end_of_month(Time.utc(2024, 1, 2, 3, 4, 5))
      #   # => 2024-01-31 23:59:59.999999999 UTC
      def self.end_of_month(t)
        local_time(t, t.year, t.month, days_in_month(t.year, t.month), 23, 59, 59, 999_999_999)
      end

      # January 1st at 00:00 of `t`'s year.
      #
      # @param t [Time] the instant whose year is measured
      # @return [Time] the year's first day at midnight
      # @example
      #   Snails::DateAndTime::Calculations.beginning_of_year(Time.utc(2024, 1, 2, 3, 4, 5))
      #   # => 2024-01-01 00:00:00 UTC
      def self.beginning_of_year(t)
        local_time(t, t.year, 1, 1, 0, 0, 0, 0)
      end

      # December 31st at its inclusive end of `t`'s year.
      #
      # @param t [Time] the instant whose year is measured
      # @return [Time] the year's last day at its inclusive end
      # @example
      #   Snails::DateAndTime::Calculations.end_of_year(Time.utc(2024, 1, 2, 3, 4, 5))
      #   # => 2024-12-31 23:59:59.999999999 UTC
      def self.end_of_year(t)
        local_time(t, t.year, 12, 31, 23, 59, 59, 999_999_999)
      end

      # both instants fall on the same civil date.
      #
      # @param a [Time] one instant
      # @param b [Time] the other instant
      # @return [Boolean] true when year, month, and day match
      # @example
      #   Snails::DateAndTime::Calculations.same_day?(Time.utc(2024, 1, 2, 1), Time.utc(2024, 1, 2, 23))
      #   # => true
      def self.same_day?(a, b)
        a.year == b.year && a.month == b.month && a.day == b.day
      end

      # `t` falls on `now`'s civil date.
      #
      # @param t [Time] the instant under test
      # @param now [Time] the clock to compare against
      # @return [Boolean] true when both instants fall on the same day
      # @example
      #   Snails::DateAndTime::Calculations.today?(Time.utc(2024, 1, 2, 1), Time.utc(2024, 1, 2, 23))
      #   # => true
      def self.today?(t, now)
        same_day?(t, now)
      end

      # `t` falls on the civil date before `now`.
      #
      # @param t [Time] the instant under test
      # @param now [Time] the clock to compare against
      # @return [Boolean] true when `t` falls on the day before `now`
      # @example
      #   Snails::DateAndTime::Calculations.yesterday?(Time.utc(2024, 1, 2, 3), Time.utc(2024, 1, 3, 3))
      #   # => true
      def self.yesterday?(t, now)
        same_day?(t, days_since(now, -1))
      end

      # `t` falls on the civil date after `now`.
      #
      # @param t [Time] the instant under test
      # @param now [Time] the clock to compare against
      # @return [Boolean] true when `t` falls on the day after `now`
      # @example
      #   Snails::DateAndTime::Calculations.tomorrow?(Time.utc(2024, 1, 2, 3), Time.utc(2024, 1, 1, 3))
      #   # => true
      def self.tomorrow?(t, now)
        same_day?(t, days_since(now, 1))
      end

      # `t` is earlier than `now`.
      #
      # @param t [Time] the instant under test
      # @param now [Time] the clock to compare against
      # @return [Boolean] true when `t` precedes `now`
      # @example
      #   Snails::DateAndTime::Calculations.past?(Time.utc(2024, 1, 2), Time.utc(2024, 1, 3))
      #   # => true
      def self.past?(t, now)
        t < now
      end

      # `t` is later than `now`.
      #
      # @param t [Time] the instant under test
      # @param now [Time] the clock to compare against
      # @return [Boolean] true when `t` follows `now`
      # @example
      #   Snails::DateAndTime::Calculations.future?(Time.utc(2024, 1, 2), Time.utc(2024, 1, 1))
      #   # => true
      def self.future?(t, now)
        t > now
      end

      # `t` falls on Saturday or Sunday.
      #
      # @param t [Time] the instant under test
      # @return [Boolean] true on the weekend
      # @example
      #   Snails::DateAndTime::Calculations.on_weekend?(Time.utc(2024, 1, 6))  # => true
      def self.on_weekend?(t)
        t.wday == 0 || t.wday == 6
      end

      # `t` falls on Monday through Friday.
      #
      # @param t [Time] the instant under test
      # @return [Boolean] true on a weekday
      # @example
      #   Snails::DateAndTime::Calculations.on_weekday?(Time.utc(2024, 1, 6))  # => false
      def self.on_weekday?(t)
        !on_weekend?(t)
      end

      # `t` falls on the given Sunday-based weekday (0 Sunday … 6 Saturday).
      #
      # @param t [Time] the instant under test
      # @param wday [Integer] the Sunday-based weekday, 0 to 6
      # @return [Boolean] true when `t.wday` equals `wday`
      # @example
      #   Snails::DateAndTime::Calculations.on_wday?(Time.utc(2024, 1, 6), 6)  # => true
      def self.on_wday?(t, wday)
        t.wday == wday
      end

      # the civil date `days` days from the epoch, rendered through `local_time`
      # in `t`'s zone.
      def self.local_on(t, days, hour, min, sec, nsec)
        z = days + 719468
        era = z / 146097
        doe = z - era * 146097
        yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
        doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        mp = (5 * doy + 2) / 153
        d = doy - (153 * mp + 2) / 5 + 1
        m = mp < 10 ? mp + 3 : mp - 9
        local_time(t, yoe + era * 400 + (m <= 2 ? 1 : 0), m, d, hour, min, sec, nsec)
      end

      # The `Time` for the given civil fields in `t`'s zone. A process-zone
      # receiver rebuilds through `Time.local`, so a boundary that crosses a
      # DST transition keeps that zone's rule; any other receiver is a
      # fixed-offset value (`getlocal(offset)` or `in_time_zone(zone)`) and
      # keeps its own offset. Plain `Time` carries no zone object, so the
      # offset matching the process zone at that instant is the test for
      # "this receiver is the process zone".
      def self.local_time(t, y, mo, d, h, mi, s, nsec)
        offset = t.utc_offset
        if offset == t.getlocal.utc_offset
          Time.at(Time.local(y, mo, d, h, mi, s).to_i, nsec, :nsec)
        else
          Time.at(Time.utc(y, mo, d, h, mi, s).to_i - offset, nsec, :nsec).getlocal(offset)
        end
      end

      # Private on purpose: only the public calculations call these, so
      # they may change.
      private_class_method :local_on, :local_time
    end
  end
end
