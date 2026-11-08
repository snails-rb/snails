# frozen_string_literal: true

# the external half of logging: hold the optional transport, buffer records into
# batches, and hand a batch over without letting a transport failure become an
# app failure. The logger owns local rendering and the one-line failure report;
# this object owns the transport slot, the bounded buffer, and the periodic
# flush registration.
#
# A batch is flushed when it reaches `MAX_RECORDS` or when the scheduler runs
# `flush` once per `FLUSH_INTERVAL_SECONDS`. The transport it calls is the
# default OTLP transport, which enqueues a `Snails::LogDeliveryJob`; the HTTP
# call itself runs in that job, never on a request thread.
module Snails
  class Logger
    class Delivery
      # The batch size that hands off without waiting for the clock.
      MAX_RECORDS = 100

      # How often the scheduler flushes the buffer, in seconds.
      FLUSH_INTERVAL_SECONDS = 1

      # A batch the transport refused. It carries the record count so the
      # local failure line says how much was dropped, not just that something
      # failed.
      class DroppedBatch < StandardError
        def initialize(count, cause)
          noun = count == 1 ? "record" : "records"
          @count = count
          super("dropped " + count.to_s + " " + noun + ": " + cause.class.to_s + ": " + cause.message)
        end

        # how many records were in the dropped batch.
        #
        # @return [Integer]
        def count
          @count
        end

        # how the local line reports the loss: records are gone.
        #
        # @return [Symbol] `:error`
        def severity
          :error
        end
      end

      # A batch the database lock kept out, now waiting for the next flush.
      # Nothing was lost, so the local line is a warning: the operator sees
      # the transport waiting, not a gap in the record stream.
      class RetainedBatch < StandardError
        def initialize(count)
          noun = count == 1 ? "record" : "records"
          @count = count
          super("transport busy — kept " + count.to_s + " " + noun + " for the next flush")
        end

        # how many records are waiting for the next flush.
        #
        # @return [Integer]
        def count
          @count
        end

        # how the local line reports the wait: nothing was lost.
        #
        # @return [Symbol] `:warn`
        def severity
          :warn
        end
      end

      def initialize
        @transport = nil
        @buffer = []
        @buffer_lock = Mutex.new
        @flush_registered = false
        # One-shot note state: the first busy hand-off after a successful one
        # reports locally; repeats stay quiet so a long stall does not write a
        # line per flush.
        @blocked = false
      end

      # the object that receives structured records.
      #
      # @return [untyped] the current transport, nil when delivery is local-only
      def transport
        @transport
      end

      # replace the record destination. The contract is `deliver(records)` with
      # an Array of `Record`; nil disables remote delivery. The buffer belongs
      # to the process, not the transport, so a swap does not discard records
      # already waiting.
      #
      # @param value [untyped] an object answering `deliver`, or nil
      # @raise [ArgumentError] value is neither nil nor transport-like
      # @return [untyped] the assigned transport
      def transport=(value)
        if !value.nil? && !value.respond_to?(:deliver)
          raise ArgumentError, "Snails.logger.transport expects an object answering deliver, got " + value.class.name
        end

        @transport = value
      end

      # make this process's buffer its own: records buffered by the parent would
      # otherwise be sent by every child, and the inherited lock may be held by
      # a thread that does not exist here. The prefork servers call it as the
      # child's first statement, before the first record.
      #
      # @return [void]
      def after_fork
        @buffer_lock = Mutex.new
        @buffer = []
        @blocked = false
        transport = @transport
        if !transport.nil? && transport.respond_to?(:after_fork)
          transport.after_fork
        end
      end

      # put the periodic flush beat on this process's scheduler.
      # `ActiveJob::Launcher.start` calls it once, before it spawns the loops,
      # so the registry is never written while the scheduler iterates it. The
      # flag makes a second call a no-op: a forked child inherits the beat and
      # the flag together, or neither.
      #
      # @return [void]
      def register_flush
        return if @flush_registered

        @flush_registered = true
        ActiveJob::Scheduler.register_periodic(FLUSH_INTERVAL_SECONDS, -> { Snails.logger.flush })
      end

      # append one record to the buffer and hand the batch off when it is full.
      #
      # A non-fatal transport failure is returned for the logger to report
      # locally. A busy database keeps the batch for the next flush (a warning,
      # not a loss); any other failure drops it. This object does not write the
      # local line and does not retry a real failure. Control and fatal
      # exceptions still propagate, matching the runtime's error boundary.
      #
      # @param record [Record] the record to buffer
      # @return [Exception, nil] the non-fatal outcome, nil on success or with
      #   no transport configured
      def deliver(record)
        return nil if @transport.nil?

        batch = nil
        @buffer_lock.synchronize do
          @buffer << record
          if @buffer.length >= MAX_RECORDS
            batch = @buffer
            @buffer = []
          end
        end
        return nil if batch.nil?

        hand_off(batch)
      end

      # hand the current buffer over now, even when it is not full. The
      # scheduler calls it every `FLUSH_INTERVAL_SECONDS`; a shutting-down
      # process may call it once more. With no transport the buffer is dropped:
      # the local lines already exist, and keeping the records would send them
      # to a transport configured later.
      #
      # @return [Exception, nil] the non-fatal outcome: a retained batch while
      #   the database is busy, a dropped batch when the transport refused,
      #   nil on success or with no transport configured
      def flush
        batch = nil
        @buffer_lock.synchronize do
          batch = @buffer
          @buffer = []
        end
        return nil if batch.length == 0
        return nil if @transport.nil?

        hand_off(batch)
      end

      # The one transport call both paths share: a failure is a return value,
      # not an exception the logger or app has to rescue. The wrapper keeps
      # the batch size so the local line can report what was lost.
      #
      # A busy database is a wait, not a loss: the batch goes back to the
      # front of the buffer and the next flush retries it. Any other failure
      # drops the batch — the transport gets no retry loop of its own.
      #
      # The transport call runs inside a connection scope: a batch can hand off
      # from a thread that holds none (a request thread writing its
      # `request.completed` record after its request scope ended). A connection
      # is checked out only when the transport reaches the database — the
      # default OTLP transport encodes and enqueues, so it does not hold a pool
      # connection. A caller already inside a scope re-enters it unchanged; a
      # transport that writes to the database holds a connection for the
      # duration of its I/O.
      def hand_off(records)
        Sqlx::Database.with_connection { @transport.deliver(records) }
        @blocked = false
        nil
      rescue Exception => failure
        raise if Snails::ErrorBoundary.fatal?(failure)
        if failure.is_a?(Sqlx::Busy)
          keep_batch(records)
        else
          DroppedBatch.new(records.length, failure)
        end
      end

      # Put a busy batch back at the front of the buffer, preserving order, and
      # report the outcome. The buffer is drained on every hand-off, so a
      # retained batch cannot pile up without bound: a first busy after a
      # success is a warning that the batch is waiting, and repeats stay quiet.
      def keep_batch(records)
        failed = records.length
        note = nil
        @buffer_lock.synchronize do
          @buffer = records.concat(@buffer)
          if !@blocked
            @blocked = true
            note = RetainedBatch.new(failed)
          end
        end
        note
      end

      private :hand_off, :keep_batch
    end
  end
end
