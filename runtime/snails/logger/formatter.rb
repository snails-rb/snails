# frozen_string_literal: true

# `Snails::Logger::Formatter` — the default log line: severity letter,
# fixed-width timestamp, process id, right-aligned level, progname, and
# the message.
#
# The timestamp is fixed width in one zone, so a reader that sorts the
# lines sorts them chronologically. The pid separates prefork workers
# that share one log stream. The request id is not rendered here — the
# logger puts it in the message, so a replacement formatter receives the
# tag without reading the request context.
#
# A formatter answers `call(severity, time, progname, message)` and
# returns the full line including its newline; apps may subclass this one
# and extend `super`.
module Snails
  class Logger
    class Formatter
      # `Formatter.format_time(time)` — the timestamp rule both local log
      # lines share: the app's zone wall clock with microseconds, plus the
      # zone offset (`Z` for UTC), so a line read in another zone still names
      # the same instant. The record line calls this too, so an app string
      # call and a framework event spell an instant alike.
      #
      # @param time [Time] the instant to render
      # @return [String] the local timestamp with its offset, `…Z` for UTC
      # @example
      #   Snails::Logger::Formatter.format_time(Time.at(0).utc) # => "1970-01-01T00:00:00.000000Z" (UTC process)
      def self.format_time(time)
        local = time.getlocal
        offset = local.strftime("%:z")
        zone = offset == "+00:00" ? "Z" : offset
        local.strftime("%Y-%m-%dT%H:%M:%S.%6N") + zone
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
