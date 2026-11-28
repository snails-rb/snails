# frozen_string_literal: true

# The process-wide tracer: start spans, keep the current trace on this thread,
# and decide whether a new trace is recorded. Tracing stays off until a
# transport is set, so framework instrumentation can ask for a span on every
# request without paying for one when the app collects no traces.
#
# The app sets the transport and sample rate in config/environment.rb. Span
# delivery (batching and the OTLP transport) is a later layer; this layer owns
# the OTel span model, the current-trace stack, and the sampling decision.
require "securerandom"

module Snails
  # the process-wide tracer. Memoized so the transport and sample rate set in
  # config/environment.rb land on the same object every span reads.
  #
  # @return [Tracer] the shared tracer
  def self.tracer
    @tracer ||= Tracer.new
  end

  # the runtime's one tracer. Apps call `in_span` around their own work and set
  # `transport` to turn collection on; the framework calls `start_span` from
  # instrumentation points where a block would cost more than a nil check.
  class Tracer
    # The span kinds OTel defines. The OTLP encoder maps each to its integer;
    # a span picks one when it starts and keeps it until finish.
    KINDS = [:internal, :server, :client, :producer, :consumer]

    # The W3C id rules: lowercase hex, fixed width, never all zero. A generated
    # id is regenerated until it differs; a caller-supplied id is rejected at
    # the span and at the inbound context.
    TRACE_ID_PATTERN = /\A[0-9a-f]{32}\z/
    SPAN_ID_PATTERN = /\A[0-9a-f]{16}\z/
    ZERO_TRACE_ID = "00000000000000000000000000000000"
    ZERO_SPAN_ID = "0000000000000000"

    def initialize
      @transport = nil
      @sample_rate = nil
      @sampler = nil
    end

    # the object that receives finished span batches, or nil when tracing is
    # off.
    #
    # @return [untyped] the current transport
    def transport
      @transport
    end

    # replace the span destination. The contract is `deliver(spans)` with an
    # Array of `Span`; nil turns tracing off for spans started later. The
    # value is checked here so a typo fails where it is written, not in the
    # delivery stage.
    #
    # @param value [untyped] an object answering `deliver`, or nil
    # @raise [ArgumentError] value is neither nil nor transport-like
    # @return [untyped] the assigned transport
    def transport=(value)
      if !value.nil? && !value.respond_to?(:deliver)
        raise ArgumentError, "Snails.tracer.transport expects an object answering deliver, got " + value.class.name
      end

      @transport = value
    end

    # whether a transport is set. Framework instrumentation reads this before
    # building span-shaped work; `start_span` answers nil either way.
    #
    # @return [Boolean] true when tracing is on
    def enabled?
      !@transport.nil?
    end

    # the share of new traces to record. An unset rate follows the mode: every
    # trace in development and test, one in ten in staging and production. The
    # default applies when the app sets no rate; a set rate always wins.
    #
    # @return [Float] the sample rate between 0.0 and 1.0
    def sample_rate
      return @sample_rate unless @sample_rate.nil?

      Snails.env.development? || Snails.env.test? ? 1.0 : 0.1
    end

    # set the share of new traces to record. 0.0 is the kill switch: no new
    # trace starts even when a parent or an inbound `traceparent` asks for one.
    # A rate change applies to the next new trace; a running trace keeps
    # following its root's decision.
    #
    # @param value [Float, Integer] the sample rate between 0.0 and 1.0
    # @raise [ArgumentError] value is not a number between 0.0 and 1.0
    # @return [Float] the assigned rate
    def sample_rate=(value)
      rate = 0.0
      if value.is_a?(Integer)
        rate = value.to_f
      elsif value.is_a?(Float)
        rate = value
      else
        raise ArgumentError, "Snails.tracer.sample_rate expects a number, got " + value.class.name
      end
      if rate < 0.0 || rate > 1.0
        raise ArgumentError, "Snails.tracer.sample_rate must be between 0.0 and 1.0, got " + rate.to_s
      end

      @sample_rate = rate
      @sampler = Sampler.new(rate)
      rate
    end

    # run the block inside one span and return the block's value. When tracing
    # is off, or the new trace is not sampled, the block receives a no-op span
    # so the app does not branch on nil. A raised exception is recorded on the
    # span as an error status and an `exception` event, then raised again.
    #
    # @param name [String] the low-cardinality span name
    # @param attributes [Hash{String => Object}] initial span attributes
    # @param kind [Symbol] one of `KINDS`
    # @raise [ArgumentError] the block is missing
    # @raise [ArgumentError] a span argument is invalid
    # @return [Object] the block's return value
    # @example
    #   Snails.tracer.in_span("checkout.charge", attributes: { "order.id" => order.id }) do |span|
    #     span.set_attribute("payment.provider", "stripe")
    #   end
    def in_span(name, attributes: {}, kind: :internal)
      if !block_given?
        raise ArgumentError, "Snails.tracer.in_span requires a block"
      end

      span = start_span(name, attributes: attributes, kind: kind)
      if span.nil?
        span = NoopSpan.new(name)
        value = nil
        begin
          value = yield span
        ensure
          span.finish
        end
        return value
      end

      begin
        yield span
      rescue Exception => failure
        record_exception(span, failure)
        raise
      ensure
        span.finish
      end
    end

    # start a span and make it the current span on this thread. The span
    # becomes a child of the current span when one is active; otherwise it
    # continues an inbound trace set by `Context.begin_trace`, or starts a new
    # trace sampled at `sample_rate`. Tracing off, or a trace that is not
    # sampled, answers nil and creates no span.
    #
    # @param name [String] the low-cardinality span name
    # @param attributes [Hash{String => Object}] initial span attributes
    # @param kind [Symbol] one of `KINDS`
    # @return [Span, nil] the started span, or nil when nothing is recorded
    # @raise [ArgumentError] a span argument is invalid, once a span is created
    def start_span(name, attributes: {}, kind: :internal)
      return nil unless enabled?

      parent = Context.current_span
      trace_id = Context.trace_id
      parent_span_id = Context.parent_span_id
      parent_sampled = nil
      if !parent.nil?
        trace_id = parent.trace_id
        parent_span_id = parent.span_id
        parent_sampled = true
      elsif trace_id.nil?
        trace_id = new_trace_id
        parent_span_id = nil
      else
        parent_sampled = Context.sampled?
      end

      sampled = sampler.sample?(trace_id, parent_sampled)
      if !sampled
        # A root that is not sampled still owns this trace decision, so a
        # nested span cannot start a fresh trace and escape the sampling.
        # The stack is empty at a root, so replacing it is safe.
        if parent.nil?
          Context.begin_trace(trace_id, parent_span_id, false, Context.tracestate)
        end
        return nil
      end

      span = Span.new(
        name: name,
        trace_id: trace_id,
        span_id: new_span_id,
        parent_span_id: parent_span_id,
        kind: kind,
        start_time: Time.now.utc,
        attributes: attributes
      )
      Context.push_span(span)
      span
    end

    # the span this thread is inside, or nil outside one.
    #
    # @return [Span, nil] the current span
    def current_span
      Context.current_span
    end

    # the current span's trace id, or nil outside a span.
    #
    # @return [String, nil] the 32-hex trace id
    def trace_id
      span = current_span
      span.nil? ? nil : span.trace_id
    end

    # the W3C `traceparent` value for the current span, or nil outside one.
    # Apps may put it on outbound headers until outbound instrumentation
    # exists.
    #
    # @return [String, nil] `00-<trace-id>-<span-id>-<flags>`
    def traceparent
      span = current_span
      return nil if span.nil?

      flags = span.recording? ? "01" : "00"
      "00-" + span.trace_id + "-" + span.span_id + "-" + flags
    end

    # The sampler for the current rate. A rate set in config/environment.rb
    # creates it; an unset rate follows the mode until the mode or the rate
    # changes.
    def sampler
      rate = sample_rate
      if @sampler.nil? || @sampler.sample_rate != rate
        @sampler = Sampler.new(rate)
      end
      @sampler
    end

    # Record a failure as an error status and an `exception` event. The caller
    # re-raises the same failure; this never replaces it. A span the app closed
    # inside the block is left alone, so the original failure wins.
    def record_exception(span, failure)
      return if span.finished?

      attributes = {
        "exception.type" => failure.class.name,
        "exception.message" => failure.message
      }
      frames = failure.backtrace
      if !frames.nil? && frames.length > 0
        attributes["exception.stacktrace"] = frames.join("\n")
      end
      span.add_event("exception", attributes: attributes)
      span.set_status(:error)
    end

    # A fresh W3C trace id: 32 lowercase hex characters, never all zero.
    def new_trace_id
      id = SecureRandom.hex(16)
      while id == ZERO_TRACE_ID
        id = SecureRandom.hex(16)
      end
      id
    end

    # A fresh W3C span id: 16 lowercase hex characters, never all zero.
    def new_span_id
      id = SecureRandom.hex(8)
      while id == ZERO_SPAN_ID
        id = SecureRandom.hex(8)
      end
      id
    end

    private :sampler, :record_exception, :new_trace_id, :new_span_id
  end
end
