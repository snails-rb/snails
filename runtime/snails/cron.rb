# Cron — a five-field cron expression: parse the text once at registration,
# then answer which calendar bucket covers an instant and where the next one
# starts. A bucket is the window between two occurrences, and its start is the
# `scheduled_at` key a recurring fire enqueues with.
#
# The grammar is the OS canon (`man 5 crontab`): minute hour day-of-month
# month day-of-week, each `*`, a comma list, a range, a step (`*/5`,
# `1-15/2`), or a value with a step (`15/30` runs from 15 to the field's
# top), or a three-letter month/weekday name. The `@yearly` family
# expands at parse. A restricted day-of-month and a restricted day-of-week are
# ORed — the canon's surprising rule: `30 4 1,15 * 5` runs on the 1st, the
# 15th, and every Friday. Seconds, time zones, natural language, the
# `L`/`#`/`%`/`&`/`~` extensions, and reversed ranges are not accepted: each
# fails at parse time instead of being dropped.
#
# Time is UTC epoch seconds throughout: the scheduler compares integers and
# converts to `Time` only when it stamps `scheduled_at`. A day is one
# 86400-second step and the clock fields are precomputed sets, so a search
# costs one check per scanned day. An expressible schedule's widest gap is
# eight years (Feb 29 across a skipped century such as 2100), so the scan is
# bounded at nine.
module Snails
  class Cron
    # Three-letter names, the canon's only spelling. `january` and `monday`
    # are Fugit extensions and are rejected here.
    MONTH_NAMES = %w[JAN FEB MAR APR MAY JUN JUL AUG SEP OCT NOV DEC]
    WEEKDAY_NAMES = %w[SUN MON TUE WED THU FRI SAT]

    # The alias forms the canon defines. `@reboot` names a boot hook, not a
    # calendar schedule, so it has no bucket to answer with and is absent.
    ALIASES = {
      "@yearly" => "0 0 1 1 *",
      "@annually" => "0 0 1 1 *",
      "@monthly" => "0 0 1 * *",
      "@weekly" => "0 0 * * 0",
      "@daily" => "0 0 * * *",
      "@midnight" => "0 0 * * *",
      "@noon" => "0 12 * * *",
      "@hourly" => "0 * * * *"
    }

    # The farthest one occurrence can be from the next: Feb 29 skipped at a
    # non-leap century. Nine years (3294 daily steps) covers every expressible
    # schedule, so a search that hits this bound has found nothing to fire.
    MAX_SEARCH_DAYS = 366 * 9

    private_constant :MONTH_NAMES, :WEEKDAY_NAMES, :ALIASES, :MAX_SEARCH_DAYS

    # parse one cron expression. Registration is the rejecting point: the
    # grammar, the field ranges, and reachability are all checked here, so a
    # spec that would never fire raises instead of becoming a beat that is
    # never due.
    #
    # @param spec [String] the five-field expression, or an `@...` alias
    # @return [Cron] the parsed expression
    # @raise [ArgumentError] the text is not a cron expression this class
    #   accepts, or it selects no occurrence within the search bound
    # @example
    #   Snails::Cron.parse("0 6 * * *")     # 06:00 UTC every day
    #   Snails::Cron.parse("0 0 * * MON")   # midnight UTC every Monday
    def self.parse(spec)
      unless spec.is_a?(String)
        raise ArgumentError, "cron schedule must be a String, got " + spec.class.to_s
      end
      text = spec.strip
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
        raise ArgumentError, "cron schedule " + spec.inspect +
                             " needs 5 fields (minute hour day-of-month month day-of-week), got " +
                             fields.length.to_s
      end
      minutes = field_values(spec, fields[0], 0, 59, [], "minute")
      hours = field_values(spec, fields[1], 0, 23, [], "hour")
      days = field_values(spec, fields[2], 1, 31, [], "day of month")
      months = field_values(spec, fields[3], 1, 12, MONTH_NAMES, "month")
      wdays = field_values(spec, fields[4], 0, 7, WEEKDAY_NAMES, "day of week")
      schedule = new(text, minutes, hours, days, months, wdays,
                     days.length < 31, wdays.length < 7)
      # A schedule whose day and month fields never meet (Feb 30) would be a
      # beat that never fires. Resolving the first occurrence from the epoch
      # makes that a registration failure instead of a silent no-op.
      schedule.next_bucket_start_at(0)
      schedule
    end

    # the values one field selects, ascending. Each comma part is `*`, a value,
    # a range, or a step over either; a name resolves before a number. The
    # weekday field folds 7 into 0, so both Sunday spellings share one value.
    def self.field_values(spec, text, low, high, names, label)
      ranges = []
      text.split(",").each do |part|
        slash = part.split("/")
        if slash.length > 2
          raise ArgumentError, field_error(spec, label, part, "at most one step")
        end
        stem = slash[0].to_s
        step = 1
        if slash.length == 2
          step_text = slash[1].to_s
          unless digits_only?(step_text)
            raise ArgumentError, field_error(spec, label, part, "the step must be a number")
          end
          step = step_text.to_i
          if step <= 0
            raise ArgumentError, field_error(spec, label, part, "the step must be positive")
          end
        end
        if stem == "*"
          ranges << [ low, high, step ]
        else
          dash = stem.split("-")
          if dash.length > 2
            raise ArgumentError, field_error(spec, label, part, "a range takes one '-'")
          end
          if dash.length == 2
            first = field_value(spec, label, dash[0], low, high, names)
            last = field_value(spec, label, dash[1], low, high, names)
            if first > last
              raise ArgumentError, field_error(spec, label, part, "a range must not run backwards")
            end
            ranges << [ first, last, step ]
          else
            value = field_value(spec, label, stem, low, high, names)
            last = slash.length == 2 ? high : value
            ranges << [ value, last, step ]
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

    # one field token: a number in `low..high`, or a three-letter name.
    def self.field_value(spec, label, token, low, high, names)
      text = token.upcase
      index = 0
      while index < names.length
        return index + low if names[index] == text
        index = index + 1
      end
      unless digits_only?(text)
        raise ArgumentError, field_error(spec, label, token, "not a number or a three-letter name")
      end
      value = text.to_i
      if value < low || value > high
        raise ArgumentError, field_error(spec, label, token, "outside " + low.to_s + ".." + high.to_s)
      end
      value
    end

    # whether every byte is an ASCII digit. A cron token never carries a sign,
    # so `.to_i` alone would accept text the grammar does not.
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

    # one rejection message: names the field, the offending token, and the
    # whole expression, so a boot failure points at the registration line.
    def self.field_error(spec, label, token, reason)
      "cron " + label + " field " + token.inspect + " in " + spec.inspect + ": " + reason
    end

    private_class_method :field_values, :field_value, :digits_only?, :field_error

    # `parse` is the entry point; the constructor takes the validated field
    # sets so the instance holds only what the day matcher reads.
    def initialize(spec, minutes, hours, days, months, wdays, days_restricted, wdays_restricted)
      @spec = spec
      @minutes = minutes
      @hours = hours
      @days = days
      @months = months
      @wdays = wdays
      @days_restricted = days_restricted
      @wdays_restricted = wdays_restricted
    end

    # the start of the calendar bucket covering `epoch`: the latest occurrence
    # at or before it, as epoch seconds. This is both the fire key and the
    # boot catch-up value — a beat that restarts mid-bucket covers the bucket
    # it was alive in, and the stored (name, scheduled_at) unique key drops the
    # repeats from other processes.
    #
    # @param epoch [Integer] the instant to cover, as epoch seconds
    # @return [Integer] the covering bucket's start, as epoch seconds
    # @raise [ArgumentError] no occurrence falls within the search bound
    # @example
    #   cron = Snails::Cron.parse("0 6 * * *")
    #   cron.bucket_start_at(Time.utc(2026, 11, 18, 7, 0).to_i)
    #   # => the epoch second of 2026-11-18 06:00 UTC
    def bucket_start_at(epoch)
      day = day_start_of(epoch)
      index = 0
      found = -1
      while found < 0 && index <= MAX_SEARCH_DAYS
        if day_matches?(day)
          @hours.each do |hour|
            @minutes.each do |minute|
              candidate = day + hour * 3600 + minute * 60
              if candidate <= epoch
                found = candidate
              end
            end
          end
        end
        day = day - 86400
        index = index + 1
      end
      if found < 0
        raise ArgumentError, "cron schedule " + @spec.inspect +
                             " has no occurrence within " + MAX_SEARCH_DAYS.to_s + " days"
      end
      found
    end

    # the first bucket start strictly after `epoch`. The scheduler advances its
    # cached boundary with this, so the next fire is the next occurrence even
    # when the loop was stalled across several buckets.
    #
    # @param epoch [Integer] the instant to look past, as epoch seconds
    # @return [Integer] the next bucket's start, as epoch seconds
    # @raise [ArgumentError] no occurrence falls within the search bound
    # @example
    #   cron = Snails::Cron.parse("0 6 * * *")
    #   cron.next_bucket_start_at(Time.utc(2026, 11, 18, 6, 0).to_i)
    #   # => the epoch second of 2026-11-19 06:00 UTC
    def next_bucket_start_at(epoch)
      day = day_start_of(epoch)
      index = 0
      found = -1
      while found < 0 && index <= MAX_SEARCH_DAYS
        if day_matches?(day)
          @hours.each do |hour|
            @minutes.each do |minute|
              candidate = day + hour * 3600 + minute * 60
              if candidate > epoch && found < 0
                found = candidate
              end
            end
          end
        end
        day = day + 86400
        index = index + 1
      end
      if found < 0
        raise ArgumentError, "cron schedule " + @spec.inspect +
                             " has no occurrence within " + MAX_SEARCH_DAYS.to_s + " days"
      end
      found
    end

    private

    # whether the UTC day starting at `day` is selected by the month,
    # day-of-month, and day-of-week fields. The canon's OR rule: when both day
    # fields are restricted, either one matching is enough.
    def day_matches?(day)
      instant = Time.at(day).utc
      month = instant.mon
      mday = instant.mday
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

    # the UTC midnight at or before `epoch`.
    def day_start_of(epoch)
      epoch - (epoch % 86400)
    end
  end
end
