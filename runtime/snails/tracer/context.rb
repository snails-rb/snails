# frozen_string_literal: true

# The trace state belonging to one request or one job on this thread: the
# active span stack and the inbound trace values. The tracer reads it to pick
# a parent and a trace id; the request and job boundaries set and clear it.
#
# The stack is per thread because a request runs on one green thread. An
# inbound `traceparent` becomes the stored trace; when no span is active, a
# new root continues that trace instead of starting a new one.
module Snails
  class Tracer
    # @api internal
    module Context
      # @api internal
      # @return [Span, nil] the innermost span on this thread
      def self.current_span
        stack = Thread.current[:snails_trace_span_stack]
        return nil if stack.nil? || stack.empty?

        stack[stack.length - 1]
      end

      # @api internal
      # @param span [Span] the span to make current
      # @return [void]
      def self.push_span(span)
        stack = Thread.current[:snails_trace_span_stack]
        if stack.nil?
          stack = []
          Thread.current[:snails_trace_span_stack] = stack
        end
        stack.push(span)
      end

      # Remove the span from the stack wherever it sits. A span finished out of
      # order closes without closing the spans started after it.
      #
      # @api internal
      # @param span [Span] the span to remove
      # @return [void]
      def self.remove_span(span)
        stack = Thread.current[:snails_trace_span_stack]
        return if stack.nil?

        i = 0
        while i < stack.length
          if stack[i].equal?(span)
            stack.delete_at(i)
            return
          end
          i += 1
        end
      end

      # Start an inbound trace. The request boundary calls it after reading a
      # valid W3C `traceparent`; a broken or missing header does not call it, so
      # the tracer starts a new trace. The stack is reset because an inbound
      # trace begins a new request scope.
      #
      # @api internal
      # @param trace_id [String] the 32-hex inbound trace id
      # @param parent_span_id [String, nil] the inbound parent span id
      # @param sampled [Boolean] the inbound sampled flag
      # @param trace_state [String, nil] the opaque `tracestate`
      # @raise [ArgumentError] an id, flag, or state value is malformed
      # @return [void]
      def self.begin_trace(trace_id, parent_span_id, sampled, trace_state)
        validate_trace_id(trace_id)
        if !parent_span_id.nil?
          validate_parent_span_id(parent_span_id)
        end
        if sampled != true && sampled != false
          raise ArgumentError, "trace sampled expects true or false"
        end
        if !trace_state.nil? && !trace_state.is_a?(String)
          raise ArgumentError, "trace_state expects a String or nil"
        end

        Thread.current[:snails_trace_span_stack] = []
        Thread.current[:snails_trace_id] = trace_id
        Thread.current[:snails_trace_parent_span_id] = parent_span_id
        Thread.current[:snails_trace_sampled] = sampled
        Thread.current[:snails_trace_state] = trace_state
      end

      # Clear the span stack and the inbound trace values. A request or job
      # boundary calls it at the end of its scope so a reused worker thread
      # cannot inherit the previous unit's trace.
      #
      # @api internal
      # @return [void]
      def self.end_trace
        Thread.current[:snails_trace_span_stack] = nil
        Thread.current[:snails_trace_id] = nil
        Thread.current[:snails_trace_parent_span_id] = nil
        Thread.current[:snails_trace_sampled] = nil
        Thread.current[:snails_trace_state] = nil
      end

      # @api internal
      # @return [String, nil] the current span's trace id, or the inbound one
      def self.trace_id
        span = current_span
        return span.trace_id unless span.nil?

        Thread.current[:snails_trace_id]
      end

      # @api internal
      # @return [String, nil] the current span's id, or the inbound parent id
      def self.parent_span_id
        span = current_span
        return span.span_id unless span.nil?

        Thread.current[:snails_trace_parent_span_id]
      end

      # @api internal
      # @return [Boolean, nil] the current recording decision, nil with no
      #   inbound trace and no current span
      def self.sampled?
        span = current_span
        return span.recording? unless span.nil?

        Thread.current[:snails_trace_sampled]
      end

      # @api internal
      # @return [String, nil] the inbound `tracestate`, preserved as opaque
      def self.trace_state
        Thread.current[:snails_trace_state]
      end

      def self.validate_trace_id(value)
        if !value.is_a?(String) || !Tracer::TRACE_ID_PATTERN.match?(value)
          raise ArgumentError, "inbound trace_id expects 32 lowercase hex characters"
        end
        if value == Tracer::ZERO_TRACE_ID
          raise ArgumentError, "inbound trace_id must not be all zero"
        end
      end

      def self.validate_parent_span_id(value)
        if !value.is_a?(String) || !Tracer::SPAN_ID_PATTERN.match?(value)
          raise ArgumentError, "inbound parent span id expects 16 lowercase hex characters"
        end
        if value == Tracer::ZERO_SPAN_ID
          raise ArgumentError, "inbound parent span id must not be all zero"
        end
      end

      private_class_method :validate_trace_id, :validate_parent_span_id
    end
  end
end
