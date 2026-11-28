# frozen_string_literal: true

# The OTLP/HTTP JSON encoder for one trace batch: resourceSpans → scopeSpans →
# spans. The transport owns the HTTP call; this file owns the wire shape and
# the enum/hex/nano conversions.
#
# The status message is only emitted with `:error`; the span model rejects a
# message on any other status.
module Snails
  class Tracer
    class OTLPEncoder
      # OTLP kind integers: internal=1, server=2, client=3, producer=4,
      # consumer=5.
      KIND_INTERNAL = 1
      KIND_SERVER = 2
      KIND_CLIENT = 3
      KIND_PRODUCER = 4
      KIND_CONSUMER = 5

      # OTLP status integers: unset=0, ok=1, error=2.
      STATUS_UNSET = 0
      STATUS_OK = 1
      STATUS_ERROR = 2

      # Encode one batch. All spans share the process resource and the tracer
      # scope; the caller supplies both so a fixture can pin the values.
      #
      # @api internal
      # @param spans [Array<Span>] the finished spans
      # @param resource [Hash{String => Object}] the resource attribute bag
      # @param scope_version [String] the tracer scope version
      # @return [Hash{String => Object}] the OTLP traces JSON structure
      def self.encode(spans, resource, scope_version)
        encoded_spans = []
        spans.each { |span| encoded_spans << span_json(span) }
        {
          "resourceSpans" => [
            {
              "resource" => { "attributes" => attributes(resource) },
              "scopeSpans" => [
                {
                  "scope" => { "name" => "snails.tracer", "version" => scope_version },
                  "spans" => encoded_spans
                }
              ]
            }
          ]
        }
      end

      def self.span_json(span)
        out = {
          "traceId" => span.trace_id,
          "spanId" => span.span_id,
          "name" => span.name,
          "kind" => kind_code(span.kind),
          "startTimeUnixNano" => time_unix_nano(span.start_time)
        }
        parent = span.parent_span_id
        out["parentSpanId"] = parent unless parent.nil?
        out["endTimeUnixNano"] = time_unix_nano(span.end_time) unless span.end_time.nil?
        out["attributes"] = attributes(span.attributes)
        events = span.events
        out["events"] = events_json(events) unless events.empty?
        out["status"] = status_json(span)
        out
      end

      def self.events_json(events)
        out = []
        events.each do |event|
          out << {
            "timeUnixNano" => time_unix_nano(event["time"]),
            "name" => event["name"],
            "attributes" => attributes(event["attributes"])
          }
        end
        out
      end

      def self.status_json(span)
        code = status_code(span.status)
        out = { "code" => code }
        message = span.status_message
        out["message"] = message unless message.nil?
        out
      end

      def self.attributes(fields)
        out = []
        fields.each do |name, value|
          any = any_value(value)
          out << { "key" => name, "value" => any } unless any.nil?
        end
        out
      end

      # OTLP AnyValue: strings, ints, doubles, and booleans. nil is omitted so
      # the receiver never has to interpret a null attribute.
      def self.any_value(value)
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

      # The OTLP backend stores nanoseconds; Time carries microseconds.
      def self.time_unix_nano(time)
        (time.to_i * 1000000000 + time.usec * 1000).to_s
      end

      def self.kind_code(kind)
        case kind
        when :internal then KIND_INTERNAL
        when :server then KIND_SERVER
        when :client then KIND_CLIENT
        when :producer then KIND_PRODUCER
        when :consumer then KIND_CONSUMER
        else
          raise ArgumentError, "unknown span kind: " + kind.to_s
        end
      end

      def self.status_code(status)
        case status
        when :unset then STATUS_UNSET
        when :ok then STATUS_OK
        when :error then STATUS_ERROR
        else
          raise ArgumentError, "unknown span status: " + status.to_s
        end
      end

      private_class_method :span_json, :events_json, :status_json
      private_class_method :attributes, :any_value, :time_unix_nano
      private_class_method :kind_code, :status_code
    end
  end
end
