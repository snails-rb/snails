# Cron — a five-field crontab expression. Parse it once when the schedule is
# declared, then ask it for the occurrence that is due now and for the one
# after it. An occurrence is one scheduled run of the job; its time is a UTC
# epoch second, and that value is the `scheduled_at` the job is enqueued with.
#
# The grammar is the one `man 5 crontab` documents: minute hour day-of-month
# month day-of-week, where each field is `*`, a comma list, an inclusive range,
# a step on `*` or on a range (`*/5`, `1-15/2`), or a three-letter month or
# weekday name. The calendar aliases (`@yearly` and friends) expand at parse.
# When both day fields are restricted they are ORed: `30 4 1,15 * 5` runs on
# the 1st, the 15th, and every Friday.
#
# Everything else a cron dialect accepts fails at parse — for example a
# seconds field, a time zone, natural language, `L`/`#`/`%`/`&`/`~`, `@reboot`,
# `@noon`, full names, and hour 24. Each message names the field and the whole
# expression.
#
# Time is UTC epoch seconds. A day is one 86400-second step, and the hour and
# minute values are precomputed, so a search costs one check per day it scans.
# The longest gap between two occurrences is eight years (Feb 29 across a
# century year that is not a leap year, such as 2100), so nine years is the
# search limit: a schedule with no occurrence inside that span can never run.
module Snails
  class Cron
    # Three-letter names, the only spelling `man 5 crontab` defines.
    MONTH_NAMES = %w[JAN FEB MAR APR MAY JUN JUL AUG SEP OCT NOV DEC]
    WEEKDAY_NAMES = %w[SUN MON TUE WED THU FRI SAT]

    # The calendar aliases from `man 5 crontab`. `@reboot` names a boot hook,
    # not a schedule, so it has no occurrence to answer with and is absent.
    ALIASES = {
      "@yearly" => "0 0 1 1 *",
      "@annually" => "0 0 1 1 *",
      "@monthly" => "0 0 1 * *",
      "@weekly" => "0 0 * * 0",
      "@daily" => "0 0 * * *",
      "@midnight" => "0 0 * * *",
      "@hourly" => "0 * * * *"
    }

    # The search limit in days. Feb 29 in a century year that is not a leap
    # year (2100) is the longest gap a schedule can have, so nine years covers
    # every schedule that can run at all.
    MAX_SEARCH_DAYS = 366 * 9

    private_constant :MONTH_NAMES, :WEEKDAY_NAMES, :ALIASES, :MAX_SEARCH_DAYS

    # Parse one cron expression. Every check runs here — the grammar, the field
    # ranges, and whether the schedule can ever run — so a bad schedule fails
    # where it is declared, not on the scheduler's first pass. A schedule with
    # no possible occurrence is rejected instead of becoming a job that
    # silently never runs.
    #
    # @param expression [String] the five-field expression, or an `@...` alias
    # @return [Cron] the parsed expression
    # @raise [ArgumentError] the text is not a cron expression this class
    #   accepts, or it has no occurrence within the search limit
    # @example
    #   Snails::Cron.parse("0 6 * * *")     # 06:00 UTC every day
    #   Snails::Cron.parse("0 0 * * MON")   # midnight UTC every Monday
    def self.parse(expression)
      unless expression.is_a?(String)
        raise ArgumentError, "cron schedule must be a String, got " + expression.class.to_s
      end
      text = expression.strip
      if text.start_with?("@")
        alias_text = ALIASES[text]
        if alias_text == nil
          raise ArgumentError, "unknown cron alias " + text.inspect +
                               " (known: " + ALIASES.keys.join(", ") + ")"
        end
        text = alias_text
      end
      fields = text.split(" ")
      if fields.length != 5
        raise ArgumentError, "cron schedule " + expression.inspect +
                             " needs 5 fields (minute hour day-of-month month day-of-week), got " +
                             fields.length.to_s
      end
      minutes = field_values(expression, fields[0], 0, 59, [], "minute")
      hours = field_values(expression, fields[1], 0, 23, [], "hour")
      days = field_values(expression, fields[2], 1, 31, [], "day of month")
      months = field_values(expression, fields[3], 1, 12, MONTH_NAMES, "month")
      wdays = field_values(expression, fields[4], 0, 7, WEEKDAY_NAMES, "day of week")
      schedule = new(text, minutes, hours, days, months, wdays,
                     days.length < 31, wdays.length < 7)
      # A schedule whose day and month fields never meet (Feb 30) would never
      # run. Resolving the first occurrence here makes that a registration
      # failure instead of a silent no-op.
      schedule.occurrence_after(0)
      schedule
    end

    # The values one field selects, ascending. Each comma part is `*`, a value,
    # or a range, and a step may follow `*` or a range; a name is resolved
    # before a number. The weekday field folds 7 into 0, so both Sunday
    # spellings give one value.
    def self.field_values(expression, text, low, high, names, label)
      ranges = []
      text.split(",").each do |part|
        slash = part.split("/")
        if slash.length > 2
          raise ArgumentError, field_error_message(expression, label, part, "at most one step")
        end
        stem = slash[0].to_s
        step = 1
        if slash.length == 2
          step_text = slash[1].to_s
          unless digits_only?(step_text)
            raise ArgumentError, field_error_message(expression, label, part, "the step must be a number")
          end
          step = step_text.to_i
          if step <= 0
            raise ArgumentError, field_error_message(expression, label, part, "the step must be positive")
          end
        end
        if stem == "*"
          ranges << [ low, high, step ]
        else
          dash = stem.split("-")
          if dash.length > 2
            raise ArgumentError, field_error_message(expression, label, part, "a range takes one '-'")
          end
          if dash.length == 2
            first = field_value(expression, label, dash[0], low, high, names)
            last = field_value(expression, label, dash[1], low, high, names)
            if first > last
              raise ArgumentError, field_error_message(expression, label, part, "a range must not run backwards")
            end
            ranges << [ first, last, step ]
          else
            if slash.length == 2
              raise ArgumentError, field_error_message(expression, label, part,
                                                       "a step needs '*' or a range (a-b/step)")
            end
            value = field_value(expression, label, stem, low, high, names)
            ranges << [ value, value, 1 ]
          end
        end
      end
      values = []
      candidate = low
      while candidate <= high
        selected = false
        ranges.each do |range|
          if candidate >= range[0] && candidate <= range[1] && (candidate - range[0]) % range[2] == 0
            selected = true
          end
        end
        if selected
          # 7 and 0 are both Sunday; only the weekday field allows 7.
          value = (candidate == 7 && high == 7) ? 0 : candidate
          values << value unless values.include?(value)
        end
        candidate = candidate + 1
      end
      values
    end

    # One field token: a number in `low..high`, or a three-letter name.
    def self.field_value(expression, label, token, low, high, names)
      text = token.upcase
      index = 0
      while index < names.length
        return index + low if names[index] == text
        index = index + 1
      end
      unless digits_only?(text)
        raise ArgumentError, field_error_message(expression, label, token,
                                                 "not a number or a three-letter name")
      end
      value = text.to_i
      if value < low || value > high
        raise ArgumentError, field_error_message(expression, label, token,
                                                 "outside " + low.to_s + ".." + high.to_s)
      end
      value
    end

    # Whether every byte is an ASCII digit. `to_i` alone would read "12abc" as
    # 12, so each byte is checked instead.
    def self.digits_only?(text)
      return false if text.length == 0
      index = 0
      while index < text.length
        byte = text.getbyte(index)
        return false if byte < 48 || byte > 57
        index = index + 1
      end
      true
    end

    # The message for one rejected field: it names the field, the offending
    # token, and the whole expression, so a boot failure points at the line
    # that declared the schedule.
    def self.field_error_message(expression, label, token, reason)
      "cron " + label + " field " + token.inspect + " in " + expression.inspect + ": " + reason
    end

    private_class_method :field_values, :field_value, :digits_only?, :field_error_message

    # `parse` is the entry point; the constructor takes the validated fields,
    # so an instance holds the parsed schedule and nothing else.
    def initialize(expression, minutes, hours, days, months, wdays,
                   days_restricted, wdays_restricted)
      @expression = expression
      @minutes = minutes
      @hours = hours
      @days = days
      @months = months
      @wdays = wdays
      @days_restricted = days_restricted
      @wdays_restricted = wdays_restricted
    end

    # The latest occurrence at or before `now`, as epoch seconds. A process
    # that starts after an occurrence's time still runs it once, and the unique
    # (job_name, scheduled_at) key keeps another process from enqueueing it
    # again.
    #
    # @param now [Integer] the instant to look back from, as epoch seconds
    # @return [Integer] the occurrence's time, as epoch seconds
    # @raise [ArgumentError] no occurrence falls within the search limit
    # @example
    #   cron = Snails::Cron.parse("0 6 * * *")
    #   cron.occurrence_at_or_before(Time.utc(2026, 11, 18, 7, 0).to_i)
    #   # => the epoch second of 2026-11-18 06:00 UTC
    def occurrence_at_or_before(now)
      day = start_of_day(now)
      index = 0
      found = -1
      while found < 0 && index <= MAX_SEARCH_DAYS
        if day_matches?(day)
          @hours.each do |hour|
            @minutes.each do |minute|
              candidate = day + hour * 3600 + minute * 60
              if candidate <= now
                found = candidate
              end
            end
          end
        end
        day = day - 86400
        index = index + 1
      end
      if found < 0
        raise ArgumentError, "cron schedule " + @expression.inspect +
                             " has no occurrence within " + MAX_SEARCH_DAYS.to_s + " days"
      end
      found
    end

    # The first occurrence strictly after `now`, as epoch seconds. The
    # scheduler advances its next due time with this.
    #
    # @param now [Integer] the instant to look forward from, as epoch seconds
    # @return [Integer] the occurrence's time, as epoch seconds
    # @raise [ArgumentError] no occurrence falls within the search limit
    # @example
    #   cron = Snails::Cron.parse("0 6 * * *")
    #   cron.occurrence_after(Time.utc(2026, 11, 18, 6, 0).to_i)
    #   # => the epoch second of 2026-11-19 06:00 UTC
    def occurrence_after(now)
      day = start_of_day(now)
      index = 0
      found = -1
      while found < 0 && index <= MAX_SEARCH_DAYS
        if day_matches?(day)
          @hours.each do |hour|
            @minutes.each do |minute|
              candidate = day + hour * 3600 + minute * 60
              if candidate > now && found < 0
                found = candidate
              end
            end
          end
        end
        day = day + 86400
        index = index + 1
      end
      if found < 0
        raise ArgumentError, "cron schedule " + @expression.inspect +
                             " has no occurrence within " + MAX_SEARCH_DAYS.to_s + " days"
      end
      found
    end

    private

    # Whether the UTC day starting at `day` matches the month, day-of-month,
    # and day-of-week fields. Crontab's OR rule: when both day fields are
    # restricted, either one matching is enough.
    def day_matches?(day)
      time = Time.at(day).utc
      month = time.mon
      mday = time.mday
      return false unless @months.include?(month)
      weekday = (day / 86400 + 4) % 7
      dom = @days.include?(mday)
      dow = @wdays.include?(weekday)
      if @days_restricted && @wdays_restricted
        dom || dow
      elsif @days_restricted
        dom
      elsif @wdays_restricted
        dow
      else
        true
      end
    end

    # The UTC midnight at or before `now`.
    def start_of_day(now)
      now - (now % 86400)
    end
  end
end
