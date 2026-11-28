# frozen_string_literal: true

# The span an app receives when tracing is off or a new trace is not sampled.
# Every operation does nothing, so `in_span` can yield a span unconditionally;
# the app never branches on nil.
module Snails
  class Tracer
    # The span an app receives when tracing is off or a new trace is not
    # sampled. Every operation does nothing, so `in_span` can yield a span
    # unconditionally; the app never branches on nil.
    class NoopSpan
      # @api internal
      # @param name [String] the requested span name
      # @return [void]
      def initialize(name)
        @name = name
      end

      # the name the block asked for; kept only for inspection.
      #
      # @return [String] the requested span name
      def name
        @name
      end

      # whether this span records its fields. A no-op span never does.
      #
      # @return [Boolean] false
      def recording?
        false
      end

      # whether `finish` already ran. A no-op span has no state to close.
      #
      # @return [Boolean] false
      def finished?
        false
      end

      # @return [nil] a no-op span has no trace id
      def trace_id
        nil
      end

      # @return [nil] a no-op span has no span id
      def span_id
        nil
      end

      # @return [nil] a no-op span has no parent
      def parent_span_id
        nil
      end

      # @return [Symbol] `:internal`
      def kind
        :internal
      end

      # @return [nil] a no-op span has no start time
      def start_time
        nil
      end

      # @return [nil] a no-op span has no end time
      def end_time
        nil
      end

      # @return [Hash{String => Object}] an empty attribute bag
      def attributes
        {}
      end

      # @return [Array<Hash{String => Object}>] an empty link list
      def links
        []
      end

      # @return [Array<Hash{String => Object}>] an empty event list
      def events
        []
      end

      # @return [Symbol] `:unset`
      def status
        :unset
      end

      # @return [nil] a no-op span has no status message
      def status_message
        nil
      end

      # @param name [String] the ignored span name
      # @return [String] the name, unchanged
      def set_name(name)
        name
      end

      # @param key [String] the ignored attribute name
      # @param value [Object] the ignored attribute value
      # @return [Object] the value, unchanged
      def set_attribute(key, value)
        value
      end

      # @param name [String] the ignored event name
      # @param attributes [Hash{String => Object}] the ignored event attributes
      # @return [void]
      def add_event(name, attributes: {})
      end

      # @param status [Symbol] the ignored status
      # @param message [String, nil] the ignored status message
      # @return [Symbol] the status, unchanged
      def set_status(status, message: nil)
        status
      end

      # @return [void]
      def finish
      end
    end
  end
end
