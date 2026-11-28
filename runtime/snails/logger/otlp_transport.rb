# frozen_string_literal: true

# The default logs transport: encode one batch as OTLP logs JSON and enqueue
# `Snails::LogDeliveryJob`, so the HTTP call never blocks a request.
#
# The endpoint, token, session, retry, and `v1/logs` path live in the shared
# OTLP HTTP helper; this file owns only the logs encoder and the job handoff.
require "securerandom"

module Snails
  class Logger
    class OTLPTransport
      # Compatibility aliases for the constants and error the transport
      # exposed before the HTTP layer moved to `Snails::OTLP::HTTP`.
      OPEN_TIMEOUT = Snails::OTLP::HTTP::OPEN_TIMEOUT
      READ_TIMEOUT = Snails::OTLP::HTTP::READ_TIMEOUT
      MAX_ATTEMPTS = Snails::OTLP::HTTP::MAX_ATTEMPTS

      # The failure `send_encoded` raises for a non-2xx response. The shared
      # HTTP helper raises `Snails::OTLP::DeliveryError`; the transport keeps
      # its own class so existing rescues stay valid.
      class DeliveryError < Snails::OTLP::DeliveryError
      end

      # configure the destination. The endpoint is the receiver's base URL
      # (scheme, host, and optional path prefix); the shared helper appends the
      # OTLP logs path. A trailing slash on the base is absorbed. The token is
      # sent as `Authorization: Bearer`. Both are validated here so a typo fails
      # at boot rather than on the first batch.
      #
      # @param endpoint [String] the base `http` or `https` URL
      # @param token [String] the ingest token
      # @raise [ArgumentError] endpoint or token is empty or malformed
      def initialize(endpoint:, token:)
        @executor_warned = false
        @http = Snails::OTLP::HTTP.new(endpoint: endpoint, token: token, path: "v1/logs")
      end

      # the resolved logs URL, for diagnostics and tests.
      #
      # @api internal
      # @return [URI] the full endpoint URL
      def url
        @http.url
      end

      # drop the parent's HTTP session in a forked child. The socket and the
      # lock belong to the parent process; a child that inherited them would
      # write on a connection another process owns.
      #
      # @return [void]
      def after_fork
        @http.after_fork
      end

      # encode one batch and enqueue the delivery job. It never performs HTTP;
      # the transport contract stays the delivery point.
      #
      # A process without a registered executor would run the job at the call
      # site and block the caller, so that case is refused. The first refusal
      # is reported to the logger; later batches stay local without repeating
      # the warning.
      #
      # @param records [Array<Record>] the buffered records
      # @return [void]
      # @raise [RuntimeError] no executor is registered, on the first batch
      def deliver(records)
        return nil if records.length == 0
        if !ActiveJob.executor_registered
          if !@executor_warned
            @executor_warned = true
            raise "log delivery needs a worker loop"
          end
          return nil
        end

        body = encode(records, new_batch_id)
        ActiveJob.enqueue(Snails::LogDeliveryJob, body)
      end

      # post one encoded OTLP batch. The shared helper owns the 4xx/5xx and
      # network retry contract; the transport maps its error class back to the
      # long-standing logs class.
      #
      # @param body [Hash] the OTLP logs JSON structure
      # @return [Boolean] true when the endpoint answered 2xx
      # @raise [DeliveryError] the endpoint refused the batch, or the retry
      #   budget was spent
      def send_encoded(body)
        begin
          @http.send_encoded(body)
        rescue Snails::OTLP::DeliveryError => failure
          raise DeliveryError.new(failure.message, failure.status)
        end
      end

      private

      # The OTLP envelope for one batch. All records in a batch share the
      # process resource; the first record's bag is the batch's resource.
      def encode(records, batch_id)
        first = records[0]
        log_records = []
        seq = 0
        records.each do |record|
          log_records << log_record(record, batch_id, seq)
          seq = seq + 1
        end
        {
          "resourceLogs" => [
            {
              "resource" => { "attributes" => attributes(first.resource) },
              "scopeLogs" => [
                {
                  "scope" => { "name" => "snails.logger" },
                  "logRecords" => log_records
                }
              ]
            }
          ]
        }
      end

      def log_record(record, batch_id, seq)
        attributes_out = [
          { "key" => "event.name", "value" => { "stringValue" => record.event } }
        ]
        append_attributes(attributes_out, record.fields)
        type = record.exception_type
        if !type.nil?
          attributes_out << { "key" => "exception.type", "value" => { "stringValue" => type } }
        end
        exception_message = record.exception_message
        if !exception_message.nil?
          attributes_out << { "key" => "exception.message", "value" => { "stringValue" => exception_message } }
        end
        stacktrace = record.exception_stacktrace
        if !stacktrace.nil?
          attributes_out << { "key" => "exception.stacktrace", "value" => { "stringValue" => stacktrace } }
        end
        attributes_out << { "key" => "snails.batch_id", "value" => { "stringValue" => batch_id } }
        attributes_out << { "key" => "snails.seq", "value" => { "intValue" => seq.to_s } }
        out = {
          "timeUnixNano" => time_unix_nano(record.time),
          "severityNumber" => severity_number(record.severity),
          "severityText" => record.severity.to_s.upcase,
          "body" => { "stringValue" => record.body },
          "attributes" => attributes_out
        }
        # OTLP log correlation fields are top-level record fields, not
        # attributes, so a backend joins them to spans without scanning the
        # attribute bag.
        if !record.trace_id.nil?
          out["traceId"] = record.trace_id
          out["spanId"] = record.span_id
          out["flags"] = record.trace_flags
        end
        out
      end

      def append_attributes(out, fields)
        fields.each do |name, value|
          any = any_value(value)
          out << { "key" => name, "value" => any } unless any.nil?
        end
      end

      def attributes(fields)
        out = []
        append_attributes(out, fields)
        out
      end

      # OTLP AnyValue: strings, ints, doubles, and booleans. nil is omitted so
      # the receiver never has to interpret a null attribute.
      def any_value(value)
        if value.is_a?(String)
          { "stringValue" => value }
        elsif value.is_a?(Integer)
          { "intValue" => value.to_s }
        elsif value.is_a?(Float)
          { "doubleValue" => value }
        elsif value == true || value == false
          { "boolValue" => value }
        end
      end

      # The OTLP backend stores microseconds; the last three digits are the
      # precision the record's Time carries.
      def time_unix_nano(time)
        (time.to_i * 1000000000 + time.usec * 1000).to_s
      end

      def severity_number(severity)
        case severity
        when :debug then 5
        when :info then 9
        when :warn then 13
        when :error then 17
        when :fatal then 21
        else
          raise ArgumentError, "unknown log severity: " + severity.to_s
        end
      end

      # Per batch, not per process: a forked child or a retried batch must not
      # share an id with another batch.
      def new_batch_id
        Process.pid.to_s + "-" + SecureRandom.hex(8)
      end
    end
  end
end
