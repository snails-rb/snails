require_relative "test_helper"
require_relative "harness_runner"

# Snails::Logger::Delivery (core) — the external half of logging. It owns the
# transport slot, hands one record over, and returns a non-fatal failure
# instead of raising; the logger turns that into a local line.
class LoggerDeliveryTest < TestBase
  class Capture
    def initialize
      @batches = []
    end

    def batches
      @batches
    end

    def deliver(records)
      @batches << records
    end
  end

  class RaisingTransport
    def initialize
      @calls = 0
    end

    def calls
      @calls
    end

    def deliver(records)
      @calls = @calls + 1
      raise "transport down"
    end
  end

  # Answers "the database is locked" once, then accepts — the shape of a
  # hand-off that lands inside a stalled write.
  class BusyOnceTransport
    def initialize
      @batches = []
      @busy = true
    end

    def batches
      @batches
    end

    def deliver(records)
      if @busy
        @busy = false
        raise Sqlx::Busy.new("database is locked")
      end
      @batches << records
    end
  end

  # Stays locked out, so the note's one-shot rule can be observed.
  class BusyTransport
    def initialize
      @calls = 0
    end

    def calls
      @calls
    end

    def deliver(records)
      @calls = @calls + 1
      raise Sqlx::Busy.new("database is locked")
    end
  end

  # A transport with process-local state (the OTLP session) answers the
  # after-fork hook so the child does not inherit the parent's socket.
  class ForkAwareTransport
    def initialize
      @after_fork_calls = 0
    end

    def after_fork_calls
      @after_fork_calls
    end

    def deliver(records)
    end

    def after_fork
      @after_fork_calls = @after_fork_calls + 1
    end
  end

  def assert_equal(expected, actual)
    raise("expected #{expected.inspect}, got #{actual.inspect}") unless expected == actual
  end

  def assert_argument_error(work)
    begin
      work.call
    rescue ArgumentError => e
      return e.message
    end
    raise("expected ArgumentError")
  end

  def record
    Snails::Logger::Record.new(:info, "request.completed", "GET /up 200", time: Time.at(0).utc)
  end

  # Without a transport, delivery answers nil and does nothing.
  def test_without_a_transport_answers_nil
    assert_equal nil, Snails::Logger::Delivery.new.deliver(record)
  end

  # One record is handed to the transport as a single-record batch on flush.
  def test_delivers_one_record_as_a_batch
    capture = Capture.new
    delivery = Snails::Logger::Delivery.new
    delivery.transport = capture

    assert_equal nil, delivery.deliver(record)
    assert_equal nil, delivery.flush
    assert_equal 1, capture.batches.length
    assert_equal 1, capture.batches[0].length
    assert_equal "request.completed", capture.batches[0][0].event
  end

  # A non-fatal delivery failure does not leak as an exception; it becomes a
  # return value carrying the dropped record count.
  def test_returns_a_non_fatal_failure
    transport = RaisingTransport.new
    delivery = Snails::Logger::Delivery.new
    delivery.transport = transport

    assert_equal nil, delivery.deliver(record)
    failure = delivery.flush

    assert_equal 1, transport.calls
    assert_equal true, failure.is_a?(Snails::Logger::Delivery::DroppedBatch)
    assert_equal 1, failure.count
    assert_equal :error, failure.severity
    assert_equal true, failure.message.include?("transport down")
  end

  # When a DB lock blocks the hand-off, the batch is not dropped; it moves to
  # the next flush. Expectation: the return value is a single RetainedBatch,
  # and the next flush sends that batch.
  def test_a_busy_hand_off_keeps_the_batch_for_the_next_flush
    busy = BusyOnceTransport.new
    delivery = Snails::Logger::Delivery.new
    delivery.transport = busy

    assert_equal nil, delivery.deliver(record)
    failure = delivery.flush

    assert_equal "Snails::Logger::Delivery::RetainedBatch", failure.class.to_s
    assert_equal 1, failure.count
    assert_equal :warn, failure.severity
    assert_equal true, failure.message.include?("kept 1 record")

    assert_equal nil, delivery.flush
    assert_equal 1, busy.batches.length
    assert_equal 1, busy.batches[0].length
  end

  # While the lock wait continues, the warning is not repeated on every flush —
  # it is reported once.
  def test_repeated_busy_reports_once
    busy = BusyTransport.new
    delivery = Snails::Logger::Delivery.new
    delivery.transport = busy

    delivery.deliver(record)
    first = delivery.flush
    delivery.deliver(record)
    second = delivery.flush

    assert_equal 2, busy.calls
    assert_equal "Snails::Logger::Delivery::RetainedBatch", first.class.to_s
    assert_equal nil, second
  end

  # The transport slot rejects a value that does not answer the contract at
  # assignment time.
  def test_validates_the_transport_slot
    delivery = Snails::Logger::Delivery.new
    message = assert_argument_error(-> { delivery.transport = Object.new })
    assert_equal true, message.include?("answering deliver")

    capture = Capture.new
    delivery.transport = capture
    assert_equal capture, delivery.transport
    delivery.transport = nil
    assert_equal nil, delivery.transport
  end

  # The logger's transport accessor exposes the Delivery slot as is.
  def test_logger_delegates_the_transport_slot
    logger = Snails::Logger.new
    capture = Capture.new

    logger.transport = capture
    assert_equal capture, logger.transport
    logger.transport = nil
    assert_equal nil, logger.transport
  end

  # A transport with process-local state gets the after-fork hook; one
  # without the hook is left alone.
  def test_after_fork_notifies_a_transport_that_answers_the_hook
    delivery = Snails::Logger::Delivery.new
    transport = ForkAwareTransport.new
    delivery.transport = transport

    delivery.after_fork
    assert_equal 1, transport.after_fork_calls

    delivery.transport = Capture.new
    delivery.after_fork
    assert_equal 1, transport.after_fork_calls
  end
end

FixtureRunner.run(LoggerDeliveryTest, [
  "test_without_a_transport_answers_nil",
  "test_delivers_one_record_as_a_batch",
  "test_returns_a_non_fatal_failure",
  "test_a_busy_hand_off_keeps_the_batch_for_the_next_flush",
  "test_repeated_busy_reports_once",
  "test_validates_the_transport_slot",
  "test_logger_delegates_the_transport_slot",
  "test_after_fork_notifies_a_transport_that_answers_the_hook"
])
