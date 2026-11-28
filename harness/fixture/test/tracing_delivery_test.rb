require_relative "test_helper"
require_relative "harness_runner"

# The trace delivery layer: the buffer/handoff, the delivery job, and the
# transport's executor guard.
class DeliveryCapture
  def initialize
    @batches = []
  end

  def batches
    @batches
  end

  def deliver(spans)
    @batches << spans
  end
end

class DeliveryForkCapture
  def initialize
    @batches = []
    @after_fork_calls = 0
  end

  def batches
    @batches
  end

  def after_fork_calls
    @after_fork_calls
  end

  def deliver(spans)
    @batches << spans
  end

  def after_fork
    @after_fork_calls = @after_fork_calls + 1
  end
end

class DeliveryRaisingTransport
  def deliver(spans)
    raise "down"
  end
end

class DeliverySendCapture
  def initialize
    @bodies = []
  end

  def bodies
    @bodies
  end

  def deliver(spans)
  end

  def send_encoded(body)
    @bodies << body
  end
end

class DeliverySendRaisingTransport
  def deliver(spans)
  end

  def send_encoded(body)
    raise "down"
  end
end

class TracingQueueAdapter
  SUBMITTED = []

  def self.enqueue(job_name, work, payload)
    SUBMITTED << [job_name, payload]
  end

  def self.enqueue_at(job_name, work, payload, scheduled_at)
    SUBMITTED << [job_name, payload]
  end

  def self.enqueue_once(job_name, work, payload, scheduled_at)
    SUBMITTED << [job_name, payload]
    true
  end

  def self.drain_due?
    false
  end

  def self.drain
    0
  end
end

class TraceDeliveryTest < TestBase
  TRACE_ID = "0af7651916cd43dd8448eb211c80319c"
  SPAN_ID = "b7ad6b7169203331"

  def setup
    Snails.logger.transport = nil
    Snails.logger.output = CapturedLog.new
    Snails.logger.level = :info
    Snails.tracer.transport = nil
    Snails.tracer.flush
    Snails.tracer.sample_rate = 1.0
    Snails::Tracer::Context.end_trace
    ActiveJob::EXECUTORS.clear
    ActiveJob.queue_adapter = TracingQueueAdapter
    TracingQueueAdapter::SUBMITTED.clear
  end

  def assert_equal(expected, actual)
    raise("expected #{expected.inspect}, got #{actual.inspect}") unless expected == actual
  end

  def assert_runtime_error(work)
    begin
      work.call
    rescue RuntimeError => e
      return e.message
    end
    raise("expected RuntimeError")
  end

  def build_span
    Snails::Tracer::Span.new(
      name: "app.work",
      trace_id: TRACE_ID,
      span_id: SPAN_ID,
      parent_span_id: nil,
      kind: :internal,
      start_time: Time.at(1760000000).utc
    )
  end

  # One span waits in the delivery buffer; flush hands it to the transport.
  def test_delivery_buffers_and_flushes
    delivery = Snails::Tracer::Delivery.new
    capture = DeliveryCapture.new
    delivery.transport = capture

    delivery.deliver(build_span)
    assert_equal 0, capture.batches.length
    delivery.flush
    assert_equal 1, capture.batches.length
    assert_equal 1, capture.batches[0].length
  end

  # No transport means no buffer and no handoff.
  def test_delivery_without_a_transport_is_a_noop
    delivery = Snails::Tracer::Delivery.new
    assert_equal nil, delivery.deliver(build_span)
    assert_equal nil, delivery.flush
  end

  # A transport failure becomes a DroppedBatch with the span count and error.
  def test_delivery_returns_a_dropped_batch
    delivery = Snails::Tracer::Delivery.new
    delivery.transport = DeliveryRaisingTransport.new

    delivery.deliver(build_span)
    outcome = delivery.flush
    assert_equal "Snails::Tracer::Delivery::DroppedBatch", outcome.class.to_s
    assert_equal 1, outcome.count
    assert_equal :error, outcome.severity
    assert_equal true, outcome.message.include?("down")
  end

  # after_fork drops the parent's buffer and tells the transport to drop its
  # socket.
  def test_delivery_after_fork_resets_the_buffer
    delivery = Snails::Tracer::Delivery.new
    capture = DeliveryForkCapture.new
    delivery.transport = capture
    delivery.deliver(build_span)

    delivery.after_fork
    assert_equal 1, capture.after_fork_calls
    assert_equal nil, delivery.flush
    assert_equal 0, capture.batches.length
  end

  # The delivery job posts the encoded body it receives.
  def test_trace_delivery_job_posts_the_body
    transport = DeliverySendCapture.new
    Snails.tracer.transport = transport
    body = { "resourceSpans" => [] }

    Snails::TraceDeliveryJob.perform(body)
    assert_equal 1, transport.bodies.length
    assert_equal body, transport.bodies[0]
  end

  # A send failure is one local line and then reaches the queue as a job
  # failure.
  def test_trace_delivery_job_reports_a_failure
    transport = DeliverySendRaisingTransport.new
    Snails.tracer.transport = transport
    raised = false
    begin
      Snails::TraceDeliveryJob.perform({})
    rescue StandardError => failure
      raised = true
      assert_equal "down", failure.message
    end

    assert_equal true, raised
    text = Snails.logger.output.messages.join("\n")
    assert_equal true, text.include?("[tracer] trace delivery failed: RuntimeError: down")
  end

  # No transport is a local skip, not a job failure.
  def test_trace_delivery_job_skips_without_a_transport
    Snails.tracer.transport = nil
    Snails::TraceDeliveryJob.perform({})
    text = Snails.logger.output.messages.join("\n")
    assert_equal true, text.include?("[tracer] trace delivery skipped: no OTLP transport")
  end

  # The OTLP transport encodes the batch and enqueues the delivery job; the
  # delivery job itself is not a producer span.
  def test_otlp_transport_deliver_enqueues_the_job
    ActiveJob.register_executor
    capture = DeliveryCapture.new
    Snails.tracer.transport = capture
    transport = Snails::Tracer::OTLPTransport.new(
      endpoint: "https://collector.example.com",
      token: "token"
    )

    span = build_span
    transport.deliver([span])
    assert_equal 1, TracingQueueAdapter::SUBMITTED.length
    assert_equal "Snails::TraceDeliveryJob", TracingQueueAdapter::SUBMITTED[0][0]
    expected = Snails::Tracer::OTLPEncoder.encode(
      [span],
      Snails.tracer.resource_attributes,
      Snails.version
    )
    assert_equal expected, TracingQueueAdapter::SUBMITTED[0][1]
    assert_equal 0, capture.batches.length
  end

  # Without a worker loop the first batch raises and later batches stay local.
  def test_otlp_transport_deliver_needs_a_worker_loop
    transport = Snails::Tracer::OTLPTransport.new(
      endpoint: "https://collector.example.com",
      token: "token"
    )
    span = build_span

    message = assert_runtime_error(-> { transport.deliver([span]) })
    assert_equal true, message.include?("trace delivery needs a worker loop")
    assert_equal nil, transport.deliver([span])
  end
end

FixtureRunner.run(TraceDeliveryTest, [
  "test_delivery_buffers_and_flushes",
  "test_delivery_without_a_transport_is_a_noop",
  "test_delivery_returns_a_dropped_batch",
  "test_delivery_after_fork_resets_the_buffer",
  "test_trace_delivery_job_posts_the_body",
  "test_trace_delivery_job_reports_a_failure",
  "test_trace_delivery_job_skips_without_a_transport",
  "test_otlp_transport_deliver_enqueues_the_job",
  "test_otlp_transport_deliver_needs_a_worker_loop"
])
