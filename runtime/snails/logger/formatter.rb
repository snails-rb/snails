# frozen_string_literal: true

# The default log line: severity letter, fixed-width timestamp, pid, level,
# progname, and message.
#
# The fixed width keeps lines sortable by time; the pid separates prefork
# workers. `call` returns the full line plus newline and may be called concurrently.
module Snails
  class Logger
    class Formatter
      # Zero padding for the fractional second, indexed by digit count.
      FRACTION_ZEROS = [ "000000", "00000", "0000", "000", "00", "0", "" ].freeze

      # the timestamp rule both local log lines share: the app's zone wall clock
      # with microseconds, plus the zone offset (`Z` for UTC), so a line read in
      # another zone still names the same instant. The record line calls this
      # too, so an app string call and a framework event spell an instant alike.
      #
      # The calendar fields hold for a whole second, and `strftime` on a local
      # time serializes across request threads in this runtime (measured: its
      # call rate stays flat from one thread to 32), so the date, clock, and
      # zone text are rendered once per second and reused. Only the fractional
      # second is per call.
      #
      # @param time [Time] the instant to render
      # @return [String] the local timestamp with its offset, `…Z` for UTC
      # @example
      #   Snails::Logger::Formatter.format_time(Time.at(0).utc) # => "1970-01-01T00:00:00.000000Z" (UTC process)
      def self.format_time(time)
        second = time.to_i
        zone_name = Snails.time_zone
        cache = Thread.current[:snails_log_time]
        if !cache.nil? && cache[0] == second && cache[1] == zone_name
          return cache[2] + fraction_text(time.usec) + cache[3]
        end

        local = time.getlocal
        offset = local.strftime("%:z")
        zone = offset == "+00:00" ? "Z" : offset
        prefix = local.strftime("%Y-%m-%dT%H:%M:%S.")
        Thread.current[:snails_log_time] = [ second, zone_name, prefix, zone ]
        prefix + fraction_text(time.usec) + zone
      end

      # the six-digit fractional second `%6N` renders, from the microsecond
      # the Time already holds: `usec.to_s` is far cheaper than the strftime
      # pass that would produce the same digits.
      def self.fraction_text(usec)
        text = usec.to_s
        FRACTION_ZEROS[text.length] + text
      end

      def call(severity, time, progname, message)
        severity.to_s[0, 1] + ", [" + format_time(time) + " #" + Process.pid.to_s + "] " +
          severity.to_s.rjust(5) + " -- " + progname.to_s + ": " + message.to_s + "\n"
      end

      # The rule lives in `Formatter.format_time`; the private seam stays so an
      # app subclass can change only the timestamp with `super`.
      def format_time(time)
        Formatter.format_time(time)
      end

      private :format_time
    end
  end
end
