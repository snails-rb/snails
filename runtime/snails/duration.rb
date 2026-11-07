# `Snails::Duration` — a seconds-based span, the value the `Integer` time
# units (`7.days`) return. days/hours/minutes/weeks are exact; months and
# years use average lengths (a month is 1/12 of a 365.2425-day year), so
# `1.month` is not a calendar month.
module Snails
  class Duration
    SECONDS_PER_MINUTE = 60
    SECONDS_PER_HOUR = 3600
    SECONDS_PER_DAY = 86400
    SECONDS_PER_WEEK = 604800
    SECONDS_PER_MONTH = 2629746
    SECONDS_PER_YEAR = 31556952

    def initialize(seconds)
      @seconds = seconds
    end

    # `seconds(n)` … `years(n)` — a span of `n` units. The singular and
    # plural spellings build the same value; months and years use the
    # average constants above.
    #
    # @param n [Integer] the unit count
    # @return [Duration] the span
    def self.seconds(n)
      new(n)
    end

    def self.second(n)
      new(n)
    end

    def self.minutes(n)
      new(n * SECONDS_PER_MINUTE)
    end

    def self.minute(n)
      new(n * SECONDS_PER_MINUTE)
    end

    def self.hours(n)
      new(n * SECONDS_PER_HOUR)
    end

    def self.hour(n)
      new(n * SECONDS_PER_HOUR)
    end

    def self.days(n)
      new(n * SECONDS_PER_DAY)
    end

    def self.day(n)
      new(n * SECONDS_PER_DAY)
    end

    def self.weeks(n)
      new(n * SECONDS_PER_WEEK)
    end

    def self.week(n)
      new(n * SECONDS_PER_WEEK)
    end

    def self.fortnights(n)
      new(n * SECONDS_PER_WEEK * 2)
    end

    def self.fortnight(n)
      new(n * SECONDS_PER_WEEK * 2)
    end

    def self.months(n)
      new(n * SECONDS_PER_MONTH)
    end

    def self.month(n)
      new(n * SECONDS_PER_MONTH)
    end

    def self.years(n)
      new(n * SECONDS_PER_YEAR)
    end

    def self.year(n)
      new(n * SECONDS_PER_YEAR)
    end

    # `ago()` — the instant this span before now; `until()` is its twin.
    #
    # @return [Time] the current UTC instant shifted back
    def ago
      Time.now.utc - @seconds
    end

    def until
      Time.now.utc - @seconds
    end

    # `from_now()` — the instant this span after now; `since()` is its twin.
    #
    # @return [Time] the current UTC instant shifted forward
    def from_now
      Time.now.utc + @seconds
    end

    def since
      Time.now.utc + @seconds
    end

    def to_i
      @seconds.to_i
    end

    def to_f
      @seconds.to_f
    end

    # `to_s()` — the span as its seconds count (`30.minutes.to_s` is
    # `"1800"`), which is also what string interpolation prints.
    #
    # @return [String] the seconds count
    def to_s
      @seconds.to_s
    end

    # `seconds()` — the span in seconds.
    #
    # @return [Integer] the stored seconds count
    def seconds
      @seconds
    end

    # `==(other)` — value equality: equal to another Duration or to its own
    # seconds count (`1.year == 31556952`).
    #
    # @param other [Object] a Duration or a seconds count
    # @return [Boolean] true when both sides hold the same seconds
    def ==(other)
      other.is_a?(Duration) ? @seconds == other.seconds : @seconds == other
    end

    # `<=>(other)` and the four comparisons — order against another Duration
    # or a raw seconds count. Spelled out rather than mixed in from
    # `Comparable` so every operator is a plain method on this value.
    #
    # @param other [Object] a Duration or a seconds count
    # @return [Integer, nil] -1, 0, or 1; nil when the other side cannot be
    #   compared
    def <=>(other)
      @seconds <=> (other.is_a?(Duration) ? other.seconds : other)
    end

    def <(other)
      (self <=> other) < 0
    end

    def <=(other)
      (self <=> other) <= 0
    end

    def >(other)
      (self <=> other) > 0
    end

    def >=(other)
      (self <=> other) >= 0
    end
  end
end
