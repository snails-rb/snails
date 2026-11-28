# frozen_string_literal: true

# The external half of tracing: buffer finished spans into batches and hand a
# batch to the transport. A batch flushes at `MAX_SPANS` or once per
# `FLUSH_INTERVAL_SECONDS`; the HTTP call runs in `Snails::TraceDeliveryJob`,
# never on a request or job thread.
module Snails
  class Tracer
    class Delivery
      # The batch size that hands off without waiting for the clock.
      MAX_SPANS = 500

      # How often the scheduler flushes the buffer, in seconds.
      FLUSH_INTERVAL_SECONDS = 1

      # A batch the transport refused. It carries the span count so the local
      # failure line says how much was dropped, not just that something failed.
      class DroppedBatch < StandardError
        def initialize(count, cause)
          noun = count == 1 ? "span" : "spans"
          @count = count
          super("dropped " + count.to_s + " " + noun + ": " + cause.class.to_s + ": " + cause.message)
        end

        # how many spans were in the dropped batch.
        #
        # @return [Integer]
        def count
          @count
        end

        # how the local line reports the loss: spans are gone.
        #
        # @return [Symbol] `:error`
        def severity
          :error
        end
      end

      def initialize
        @transport = nil
        @buffer = []
        @buffer_lock = Mutex.new
        @flush_registered = false
      end

      # the object that receives finished span batches.
      #
      # @return [untyped] the current transport, nil when tracing is off
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

      # make this process's buffer its own: spans buffered by the parent would
      # otherwise be sent by every child, and the inherited lock may be held by
      # a thread that does not exist here. The prefork servers call it as the
      # child's first statement, before the first span.
      #
      # @return [void]
      def after_fork
        @buffer_lock = Mutex.new
        @buffer = []
        transport = @transport
        if !transport.nil? && transport.respond_to?(:after_fork)
          transport.after_fork
        end
      end

      # put the periodic flush callback on this process's scheduler.
      # `ActiveJob::Launcher.start` calls it once, before it spawns the loops,
      # so the registry is never written while the scheduler iterates it. The
      # flag makes a second call a no-op.
      #
      # @return [void]
      def register_flush
        return if @flush_registered

        @flush_registered = true
        ActiveJob::Scheduler.register_interval(FLUSH_INTERVAL_SECONDS, ->(_occurrence) { Snails.tracer.flush })
      end

      # append one finished span to the buffer and deliver the batch when it is
      # full. A non-fatal transport failure is returned for the tracer to
      # report locally.
      #
      # @param span [Span] the finished span
      # @return [Exception, nil] the dropped batch, or nil on success or with
      #   no transport configured
      def deliver(span)
        return nil if @transport.nil?

        batch = nil
        @buffer_lock.synchronize do
          @buffer << span
          if @buffer.length >= MAX_SPANS
            batch = @buffer
            @buffer = []
          end
        end
        return nil if batch.nil?

        deliver_batch(batch)
      end

      # deliver the current buffer now, even when it is not full. The periodic
      # scheduler calls it every `FLUSH_INTERVAL_SECONDS`; a shutting-down
      # process may call it once more. With no transport the buffer is dropped:
      # keeping the spans would send them to a transport configured later.
      #
      # @return [Exception, nil] the dropped batch, or nil on success or with
      #   no transport configured
      def flush
        batch = nil
        @buffer_lock.synchronize do
          batch = @buffer
          @buffer = []
        end
        return nil if batch.length == 0
        return nil if @transport.nil?

        deliver_batch(batch)
      end

      # The one transport call both paths share: a failure is a return value,
      # not an exception the tracer or app has to rescue. Control and fatal
      # exceptions still propagate, matching the runtime's error boundary.
      def deliver_batch(spans)
        @transport.deliver(spans)
        nil
      rescue Exception => failure
        raise if Snails::ErrorBoundary.fatal?(failure)
        DroppedBatch.new(spans.length, failure)
      end

      private :deliver_batch
    end
  end
end
