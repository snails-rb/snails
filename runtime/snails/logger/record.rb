# frozen_string_literal: true

# One log event as a field bag: time, severity, stable event name, body,
# structured fields, and an optional exception — the transport contract.
#
# Values are String, Integer, finite Float, true/false, or nil; caller fields
# may not shadow the record's own names or the request/job context.
module Snails
  class Logger
    class Record
      # Severities in increasing order — the same vocabulary the logger's
      # level check accepts.
      SEVERITIES = [ :debug, :info, :warn, :error, :fatal ].freeze

      # The field contract version — bump when a field is renamed or removed.
      SCHEMA_VERSION = 1

      # Names the record owns, plus the context fields the logger sets. A
      # caller field with one of these names is refused rather than silently
      # overwriting the record's identity or correlation data.
      RESERVED_FIELDS = [
        "event.name",
        "body",
        "severity",
        "severityNumber",
        "severityText",
        "timeUnixNano",
        "snails.request_id",
        "snails.controller",
        "snails.action",
        "snails.job.name",
        "snails.job.id",
        "snails.job.attempt",
        "snails.batch_id",
        "snails.seq",
        "exception.type",
        "exception.message",
        "exception.stacktrace",
        "service.name",
        "service.version",
        "host.name",
        "process.pid",
        "deployment.environment.name",
        "snails.version",
        "snails.rev",
        "snails.log.schema_version"
      ].freeze

      # A field name is one or more dot-separated identifiers; the underscore
      # and hyphen cover OTel and snails names without allowing whitespace or
      # punctuation that would make a key ambiguous.
      FIELD_PATTERN = /\A[A-Za-z][A-Za-z0-9_.-]*\z/

      # The trace correlation names the record carries outside its field bag.
      # They become OTLP log record `traceId`/`spanId`/`flags`, not attributes.
      TRACE_FIELDS = [ "trace_id", "span_id", "trace_flags" ].freeze

      # W3C ids the tracer produces. A record refuses a malformed pair so a
      # transport cannot emit a correlation the receiver will reject.
      TRACE_ID_PATTERN = /\A[0-9a-f]{32}\z/
      SPAN_ID_PATTERN = /\A[0-9a-f]{16}\z/
      MAX_TRACE_FLAGS = 255

      # An event name is lowercase dot-separated segments: `request.completed`,
      # `job.failed`, `worker.loop_stopped`, `app.log`.
      EVENT_PATTERN = /\A[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+\z/

      # build one record. `fields` are caller-owned and checked against
      # `RESERVED_FIELDS`; `context` carries the request/job correlation the
      # logger already validated, so those names are allowed there; `resource`
      # carries the service/process attributes the transport sends per batch;
      # `trace` carries the active span's ids as `trace_id`, `span_id`, and
      # `trace_flags`, separate from both bags.
      #
      # @param severity [Symbol] one of `SEVERITIES`
      # @param event [String] the stable event name
      # @param body [String] the human-readable message
      # @param fields [Hash{String, Symbol => Object}] caller fields
      # @param exception [Exception, nil] the failure this record reports
      # @param time [Time, nil] the event time; defaults to the current UTC time
      # @param context [Hash{String => Object}] logger-owned correlation fields
      # @param resource [Hash{String => Object}] service/process attributes
      # @param trace [Hash{String, Symbol => Object}, nil] the active trace ids
      # @raise [ArgumentError] a severity, event, field, value, exception,
      #   trace, or time outside the contract
      def initialize(severity, event, body, fields: {}, exception: nil, time: nil, context: {}, resource: {}, trace: nil)
        if !SEVERITIES.include?(severity)
          raise ArgumentError, "Snails::Logger::Record severity expects one of :debug, :info, :warn, :error, :fatal, got " + severity.inspect
        end
        if !event.is_a?(String) || !EVENT_PATTERN.match?(event)
          raise ArgumentError, "Snails::Logger::Record event expects a lowercase dot-separated name, got " + event.inspect
        end
        if !body.is_a?(String)
          raise ArgumentError, "Snails::Logger::Record body expects a String, got " + body.class.name
        end
        if !exception.nil? && !exception.is_a?(Exception)
          raise ArgumentError, "Snails::Logger::Record exception expects an Exception or nil, got " + exception.class.name
        end
        if !time.nil? && !time.is_a?(Time)
          raise ArgumentError, "Snails::Logger::Record time expects a Time or nil, got " + time.class.name
        end

        @severity = severity
        @event = event
        @body = body
        @exception = exception
        @time = time.nil? ? Time.now.utc : time
        @fields = normalize_fields(context, false).merge(normalize_fields(fields, true))
        @resource = normalize_fields(resource, false)
        @trace_id, @span_id, @trace_flags = normalize_trace(trace)
      end

      # the record's severity.
      #
      # @return [Symbol] one of `SEVERITIES`
      def severity
        @severity
      end

      # the stable event name.
      #
      # @return [String] e.g. `request.completed`
      def event
        @event
      end

      # the human-readable message.
      #
      # @return [String]
      def body
        @body
      end

      # the caller fields merged with logger context.
      #
      # @return [Hash{String => Object}] the record's field bag
      def fields
        @fields
      end

      # the service/process attributes for the transport. The local formatter
      # does not render them; an OTLP transport sends them once per batch rather
      # than on every record.
      #
      # @return [Hash{String => Object}] the resource attribute bag
      def resource
        @resource
      end

      # the trace this record belongs to, when a span was current.
      #
      # @return [String, nil] the 32-hex trace id
      def trace_id
        @trace_id
      end

      # the current span's id within the trace.
      #
      # @return [String, nil] the 16-hex span id
      def span_id
        @span_id
      end

      # the OTel trace flags byte. `1` is the W3C sampled bit.
      #
      # @return [Integer, nil] the flags, nil when the record has no trace
      def trace_flags
        @trace_flags
      end

      # the failure this record reports, when any.
      #
      # @return [Exception, nil]
      def exception
        @exception
      end

      # the event time.
      #
      # @return [Time]
      def time
        @time
      end

      # the exception class name as a field value.
      #
      # @return [String, nil]
      def exception_type
        @exception.nil? ? nil : @exception.class.name
      end

      # the exception message as a field value.
      #
      # @return [String, nil]
      def exception_message
        @exception.nil? ? nil : @exception.message
      end

      # the backtrace joined into one string.
      #
      # @return [String, nil] nil when there is no exception or no backtrace
      def exception_stacktrace
        return nil if @exception.nil?
        frames = @exception.backtrace
        return nil if frames.nil? || frames.length == 0
        frames.join("\n")
      end

      # The trace bag is all or nothing: a record with a trace id but no span
      # id (or flags) would emit a correlation the receiver cannot use.
      def normalize_trace(trace)
        return [ nil, nil, nil ] if trace.nil?
        if !trace.is_a?(Hash)
          raise ArgumentError, "Snails::Logger::Record trace expects a Hash or nil, got " + trace.class.name
        end

        values = {}
        trace.each do |name, value|
          key = name.is_a?(Symbol) ? name.to_s : name
          if !TRACE_FIELDS.include?(key)
            raise ArgumentError, "Snails::Logger::Record trace field is unknown: " + name.inspect
          end
          if values.key?(key)
            raise ArgumentError, "Snails::Logger::Record trace field " + key + " is repeated"
          end
          values[key] = value
        end
        return [ nil, nil, nil ] if values.empty?

        missing = TRACE_FIELDS.select { |name| !values.key?(name) }
        if !missing.empty?
          raise ArgumentError, "Snails::Logger::Record trace expects trace_id, span_id, and trace_flags together; missing " + missing.join(", ")
        end

        trace_id = values["trace_id"]
        if !trace_id.is_a?(String) || !TRACE_ID_PATTERN.match?(trace_id)
          raise ArgumentError, "Snails::Logger::Record trace_id expects 32 lowercase hex characters"
        end
        span_id = values["span_id"]
        if !span_id.is_a?(String) || !SPAN_ID_PATTERN.match?(span_id)
          raise ArgumentError, "Snails::Logger::Record span_id expects 16 lowercase hex characters"
        end
        trace_flags = values["trace_flags"]
        if !trace_flags.is_a?(Integer) || trace_flags < 0 || trace_flags > MAX_TRACE_FLAGS
          raise ArgumentError, "Snails::Logger::Record trace_flags expects an Integer between 0 and 255"
        end

        [ trace_id, span_id, trace_flags ]
      end

      # Normalize names to Strings, validate their format and values, and
      # reject caller fields that would shadow the record or its context.
      def normalize_fields(fields, caller_owned)
        if !fields.is_a?(Hash)
          raise ArgumentError, "Snails::Logger::Record fields expect a Hash, got " + fields.class.name
        end
        out = {}
        fields.each do |name, value|
          key = name.is_a?(Symbol) ? name.to_s : name
          if !key.is_a?(String) || !FIELD_PATTERN.match?(key)
            raise ArgumentError, "Snails::Logger::Record field name is not a dotted identifier: " + name.inspect
          end
          if caller_owned && RESERVED_FIELDS.include?(key)
            raise ArgumentError, "Snails::Logger::Record field " + key + " is reserved"
          end
          if out.key?(key)
            raise ArgumentError, "Snails::Logger::Record field " + key + " is repeated"
          end
          validate_field_value(key, value)
          out[key] = value
        end
        out
      end

      # Only simple values cross the record boundary; a nested value would
      # make an OTLP encoding a guess and a local line ambiguous.
      def validate_field_value(name, value)
        case value
        when String, Integer, TrueClass, FalseClass, NilClass
          nil
        when Float
          if !value.finite?
            raise ArgumentError, "Snails::Logger::Record field " + name + " is not a finite Float"
          end
        else
          raise ArgumentError, "Snails::Logger::Record field " + name + " expects a String, Integer, finite Float, true/false, or nil, got " + value.class.name
        end
      end

      private :normalize_trace, :normalize_fields, :validate_field_value
    end
  end
end
