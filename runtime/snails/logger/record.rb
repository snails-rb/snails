# frozen_string_literal: true

# one log event as a field bag: when it happened, its severity and stable event
# name, a human body, structured fields, and an optional exception. It is the
# contract a transport consumes; the local line is only a rendering of this
# record.
#
# Field names are simple dotted identifiers; values are String, Integer,
# finite Float, true/false, or nil so an OTLP encoder never has to guess.
# Fields supplied by the caller may not shadow the record's own names or the
# request/job context the logger adds. `resource` is the separate bag that
# describes the emitting service and process; the local formatter does not
# render it, and the transport sends it once per batch.
module Snails
  class Logger
    class Record
      # Severities in increasing order — the same vocabulary the logger's
      # level gate accepts.
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

      # An event name is lowercase dot-separated segments: `request.completed`,
      # `job.failed`, `worker.loop_stopped`, `app.log`.
      EVENT_PATTERN = /\A[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+\z/

      # build one record. `fields` are caller-owned and checked against
      # `RESERVED_FIELDS`; `context` carries the request/job correlation the
      # logger already validated, so those names are allowed there; `resource`
      # carries the service/process attributes the transport sends per batch.
      #
      # @param severity [Symbol] one of `SEVERITIES`
      # @param event [String] the stable event name
      # @param body [String] the human-readable message
      # @param fields [Hash{String, Symbol => Object}] caller fields
      # @param exception [Exception, nil] the failure this record reports
      # @param time [Time, nil] the event time; defaults to the current UTC time
      # @param context [Hash{String => Object}] logger-owned correlation fields
      # @param resource [Hash{String => Object}] service/process attributes
      # @raise [ArgumentError] a severity, event, field, value, exception, or
      #   time outside the contract
      def initialize(severity, event, body, fields: {}, exception: nil, time: nil, context: {}, resource: {})
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

      # Normalize names to Strings, validate their shape and values, and
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

      private :normalize_fields, :validate_field_value
    end
  end
end
