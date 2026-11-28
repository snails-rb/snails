# frozen_string_literal: true

# One timed interval inside a trace: the OTel span fields and the rules that
# keep a finished span stable. A span is created by `Tracer#start_span`, becomes
# current on its thread, and is removed when it finishes.
#
# The span name is low-cardinality; values belong in attributes. Attribute
# values are limited to the scalar types OTLP JSON carries in this stage.
module Snails
  class Tracer
    class Span
      attr_reader :name, :trace_id, :span_id, :parent_span_id, :kind,
                  :start_time, :end_time, :status, :status_message

      # Build a span. The tracer calls this after the sampling decision; an
      # invalid field raises before the span enters the current-trace stack.
      #
      # @api internal
      # @param name [String] the low-cardinality span name
      # @param trace_id [String] the 32-hex trace id
      # @param span_id [String] the 16-hex span id
      # @param parent_span_id [String, nil] the parent span id, nil at a root
      # @param kind [Symbol] one of `Tracer::KINDS`
      # @param start_time [Time] the span's start
      # @param attributes [Hash{String => Object}] initial attributes
      # @raise [ArgumentError] a field is missing, malformed, or unsupported
      # @return [void]
      def initialize(name:, trace_id:, span_id:, parent_span_id:, kind:, start_time:, attributes: {})
        validate_name(name)
        validate_trace_id(trace_id)
        validate_span_id(span_id)
        if !parent_span_id.nil?
          validate_span_id(parent_span_id)
        end
        validate_kind(kind)
        if !start_time.is_a?(Time)
          raise ArgumentError, "span start_time expects a Time"
        end
        if !attributes.is_a?(Hash)
          raise ArgumentError, "span attributes expect a Hash"
        end

        @name = name
        @trace_id = trace_id
        @span_id = span_id
        @parent_span_id = parent_span_id
        @kind = kind
        @start_time = start_time
        @end_time = nil
        @attributes = {}
        @events = []
        @status = :unset
        @status_message = nil
        @finished = false
        attributes.each { |key, value| set_attribute(key, value) }
      end

      # whether this span records its fields. A real span answers true; a
      # no-op span answers false and every setter does nothing.
      #
      # @return [Boolean] true when the span retains what it is given
      def recording?
        true
      end

      # whether `finish` already ran.
      #
      # @return [Boolean] true after the span closed
      def finished?
        @finished
      end

      # the span's attributes as a copy, so a reader cannot bypass the setter's
      # validation.
      #
      # @return [Hash{String => Object}] the recorded attributes
      def attributes
        copy_attributes(@attributes)
      end

      # the span's links. Job context propagation is a later stage, so a span
      # in this stage has none.
      #
      # @return [Array<Hash{String => Object}>] an empty link list
      def links
        []
      end

      # the span's events as copies, so a reader cannot change a finished span.
      #
      # @return [Array<Hash{String => Object}>] the recorded events
      def events
        out = []
        @events.each do |event|
          out.push({
            "time" => event["time"],
            "name" => event["name"],
            "attributes" => copy_attributes(event["attributes"])
          })
        end
        out
      end

      # change the name after a start-time guess, for example once a route
      # matches. The name is frozen at finish.
      #
      # @param name [String] the low-cardinality span name
      # @raise [ArgumentError] the span is finished or the name is invalid
      # @return [String] the assigned name
      def set_name(name)
        ensure_open("name")
        validate_name(name)
        @name = name
      end

      # add one attribute. The value types are the scalar types OTLP JSON
      # carries in this stage; an unsupported value raises rather than
      # dropping the attribute.
      #
      # @param key [String] the attribute name
      # @param value [String, Integer, Float, Boolean] the attribute value
      # @raise [ArgumentError] the span is finished, the key is invalid, or the
      #   value type is unsupported
      # @return [Object] the assigned value
      def set_attribute(key, value)
        ensure_open("attribute")
        validate_attribute_key(key)
        validate_attribute_value(key, value)
        @attributes[key] = value
      end

      # add one event with its own timestamp and attributes. An exception is
      # recorded as an event named `exception` with `exception.*` attributes.
      #
      # @param name [String] the event name
      # @param attributes [Hash{String => Object}] event attributes
      # @raise [ArgumentError] the span is finished or an event field is invalid
      # @return [void]
      def add_event(name, attributes: {})
        ensure_open("event")
        validate_event_name(name)
        if !attributes.is_a?(Hash)
          raise ArgumentError, "span event attributes expect a Hash"
        end

        copied = {}
        attributes.each do |key, value|
          validate_attribute_key(key)
          validate_attribute_value(key, value)
          copied[key] = value
        end
        @events.push({ "time" => Time.now.utc, "name" => name, "attributes" => copied })
      end

      # set the OTel status. A message is developer-facing and optional.
      #
      # @param status [Symbol] one of `:unset`, `:ok`, `:error`
      # @param message [String, nil] the status message
      # @raise [ArgumentError] the span is finished or a status field is invalid
      # @return [Symbol] the assigned status
      def set_status(status, message: nil)
        ensure_open("status")
        if status != :unset && status != :ok && status != :error
          raise ArgumentError, "span status must be :unset, :ok, or :error"
        end
        if !message.nil? && !message.is_a?(String)
          raise ArgumentError, "span status message expects a String or nil"
        end

        @status = status
        @status_message = message
        status
      end

      # close the span and make its parent current again. A second call is a
      # no-op, so an `ensure` cannot close a span twice or move its end time.
      #
      # @return [void]
      def finish
        return if @finished

        @finished = true
        @end_time = Time.now.utc
        Context.remove_span(self)
      end

      # Reject a change after finish with one message shape.
      def ensure_open(what)
        if @finished
          raise ArgumentError, "span is finished; cannot change " + what
        end
      end

      def validate_name(value)
        validate_non_empty_string(value, "span name")
      end

      def validate_event_name(value)
        validate_non_empty_string(value, "span event name")
      end

      def validate_non_empty_string(value, label)
        if !value.is_a?(String) || value.empty?
          raise ArgumentError, label + " expects a non-empty String"
        end
      end

      def validate_trace_id(value)
        if !value.is_a?(String) || !Tracer::TRACE_ID_PATTERN.match?(value)
          raise ArgumentError, "span trace_id expects 32 lowercase hex characters"
        end
        if value == Tracer::ZERO_TRACE_ID
          raise ArgumentError, "span trace_id must not be all zero"
        end
      end

      def validate_span_id(value)
        if !value.is_a?(String) || !Tracer::SPAN_ID_PATTERN.match?(value)
          raise ArgumentError, "span span_id expects 16 lowercase hex characters"
        end
        if value == Tracer::ZERO_SPAN_ID
          raise ArgumentError, "span span_id must not be all zero"
        end
      end

      def validate_kind(value)
        if !Tracer::KINDS.include?(value)
          raise ArgumentError, "span kind must be one of " + Tracer::KINDS.join(", ")
        end
      end

      def validate_attribute_key(key)
        if !key.is_a?(String) || key.empty?
          raise ArgumentError, "span attribute key expects a non-empty String, got " + key.class.name
        end
      end

      def validate_attribute_value(key, value)
        if value.is_a?(String) || value.is_a?(Integer) || value.is_a?(Float) ||
           value == true || value == false
          return
        end
        raise ArgumentError, "span attribute " + key + " expects a String, Integer, Float, or Boolean, got " + value.class.name
      end

      def copy_attributes(source)
        out = {}
        source.each { |key, value| out[key] = value }
        out
      end

      private :ensure_open, :validate_name, :validate_event_name
      private :validate_non_empty_string, :validate_trace_id, :validate_span_id
      private :validate_kind, :validate_attribute_key, :validate_attribute_value
      private :copy_attributes
    end
  end
end
