# frozen_string_literal: true

# The head-based sampling decision for one tracer. A root trace is recorded
# when its trace id's ratio falls under the sample rate; a child follows the
# root's decision. A rate of 0.0 rejects every new trace, including one an
# inbound `traceparent` asked to continue.
#
# The ratio comes from the first 32 bits of the trace id, so the decision is
# reproducible from the id rather than a second random draw.
module Snails
  class Tracer
    # @api internal
    class Sampler
      # The trace id's first 32 bits span this range; the threshold is the rate
      # scaled to the same integer range.
      SCALE = 4294967296

      # @param sample_rate [Float] the share of new traces to record, 0.0..1.0
      # @raise [ArgumentError] the rate is not a Float in 0.0..1.0
      # @return [void]
      def initialize(sample_rate)
        if !sample_rate.is_a?(Float)
          raise ArgumentError, "Sampler sample_rate expects a Float, got " + sample_rate.class.name
        end
        if sample_rate < 0.0 || sample_rate > 1.0
          raise ArgumentError, "Sampler sample_rate must be between 0.0 and 1.0, got " + sample_rate.to_s
        end

        @sample_rate = sample_rate
      end

      # the rate this sampler was built with.
      #
      # @return [Float] the sample rate
      def sample_rate
        @sample_rate
      end

      # whether to record this new span. A nil parent means a new trace and
      # draws the ratio from `trace_id`; true and false carry the parent's
      # decision. A local rate of 0.0 rejects the span even when the parent was
      # sampled.
      #
      # @param trace_id [String] the 32-hex trace id the new span belongs to
      # @param parent_sampled [Boolean, nil] the parent's decision, nil at a root
      # @raise [ArgumentError] the trace id or parent flag is malformed
      # @return [Boolean] true when the span is recorded
      def sample?(trace_id, parent_sampled)
        if !trace_id.is_a?(String) || !Tracer::TRACE_ID_PATTERN.match?(trace_id)
          raise ArgumentError, "Sampler trace_id expects 32 lowercase hex characters"
        end
        if trace_id == Tracer::ZERO_TRACE_ID
          raise ArgumentError, "Sampler trace_id must not be all zero"
        end
        if parent_sampled != true && parent_sampled != false && !parent_sampled.nil?
          raise ArgumentError, "Sampler parent_sampled expects true, false, or nil"
        end
        return false if @sample_rate == 0.0
        return true if parent_sampled == true
        return false if parent_sampled == false

        threshold = (@sample_rate * SCALE).to_i
        trace_value(trace_id) < threshold
      end

      # The first 32 bits of the trace id as an integer. The id is already
      # validated as lowercase hex, so the digit mapping is fixed.
      def trace_value(trace_id)
        value = 0
        i = 0
        while i < 8
          byte = trace_id.getbyte(i)
          digit = byte - 87
          if byte >= 48 && byte <= 57
            digit = byte - 48
          end
          value = value * 16 + digit
          i += 1
        end
        value
      end

      private :trace_value
    end
  end
end
