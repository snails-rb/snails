# frozen_string_literal: true

# `Snails::Logger::RecordFormatter` — render one structured record as a
# single local line. The prefix matches the default formatter; the message is
# `event.name=…`, the record fields, exception fields, and the body. Newlines
# in bodies, stacktraces, and field values are escaped so one record never
# becomes two lines in a local log.
module Snails
  class Logger
    class RecordFormatter
      # `call(record, progname)` — the local line for one record.
      #
      # @param record [Record] the record to render
      # @param progname [String] the service name between `--` and `:`
      # @return [String] the full line, including its newline
      def call(record, progname)
        severity = record.severity.to_s.upcase
        severity.to_s[0, 1] + ", [" + format_time(record.time) + " #" + Process.pid.to_s + "] " +
          severity.rjust(5) + " -- " + progname.to_s + ": " + message(record) + "\n"
      end

      # The default formatter's rule, reused so both local lines spell an
      # instant the same way — offset included, `Z` for UTC.
      def format_time(time)
        Formatter.format_time(time)
      end

      # The field section: event first, then fields in insertion order, then
      # the exception fields, then the body.
      def message(record)
        parts = [ "event.name=" + record.event ]
        record.fields.each do |name, value|
          parts << name + "=" + field_text(value)
        end
        type = record.exception_type
        parts << "exception.type=" + type unless type.nil?
        exception_message = record.exception_message
        parts << "exception.message=" + quote_text(exception_message) unless exception_message.nil?
        stacktrace = record.exception_stacktrace
        parts << "exception.stacktrace=" + quote_text(stacktrace) unless stacktrace.nil?
        parts << "body=" + escape_text(record.body) unless record.body.empty?
        parts.join(" ")
      end

      # Numbers and booleans print bare; strings print bare when they have no
      # whitespace, quote, or backslash, and quoted otherwise. nil is spelled
      # out so the field is not mistaken for an absent one.
      def field_text(value)
        if value.is_a?(String)
          if value.match?(/[[:space:]"\\=]/)
            quote_text(value)
          else
            value
          end
        elsif value.nil?
          "nil"
        else
          value.to_s
        end
      end

      # Quote a string for the local line: escape backslash, quote, and the
      # control characters that would otherwise break the one-line contract.
      def quote_text(text)
        "\"" + escape_text(text).gsub("\"", "\\\"") + "\""
      end

      # Escape backslash and control characters without adding quotes.
      def escape_text(text)
        text.gsub("\\", "\\\\")
            .gsub("\n", "\\n")
            .gsub("\r", "\\r")
            .gsub("\t", "\\t")
      end

      private :format_time, :message, :field_text, :quote_text, :escape_text
    end
  end
end
