require_relative "test_helper"
require_relative "harness_runner"

# Snails::Tracer (core) — the span API, the current-trace stack, and the
# sampling decision. Delivery and OTLP encoding are later stages; the stub
# transport here only turns collection on so the span model can be read.
class TracerTest < TestBase
  ZERO_TRACE_ID = "00000000000000000000000000000000"
  ZERO_SPAN_ID = "0000000000000000"
  TRACE_ID = "0af7651916cd43dd8448eb211c80319c"
  SPAN_ID = "b7ad6b7169203331"

  # A transport contract stub: the tracer only checks that it answers
  # `deliver` before collection turns on.
  class CaptureTransport
    def initialize
      @batches = []
    end

    def batches
      @batches
    end

    def deliver(spans)
      @batches.push(spans)
    end
  end

  def setup
    Snails::Tracer::Context.end_trace
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

  def new_tracer
    tracer = Snails::Tracer.new
    tracer.transport = CaptureTransport.new
    tracer.sample_rate = 1.0
    tracer
  end

  def build_span(trace_id: TRACE_ID, span_id: SPAN_ID, parent_span_id: nil,
                 kind: :internal, name: "app.work")
    Snails::Tracer::Span.new(
      name: name,
      trace_id: trace_id,
      span_id: span_id,
      parent_span_id: parent_span_id,
      kind: kind,
      start_time: Time.now.utc
    )
  end

  # The global accessor memoizes one tracer, so config/environment.rb and the
  # instrumentation points write and read the same object.
  def test_accessor_returns_a_shared_tracer
    tracer = Snails.tracer
    assert_equal true, tracer.is_a?(Snails::Tracer)
    assert_equal tracer, Snails.tracer
  end

  # Without a transport, start_span answers nil and no trace value exists.
  def test_without_a_transport_creates_no_span
    tracer = Snails::Tracer.new

    assert_equal false, tracer.enabled?
    assert_equal nil, tracer.start_span("app.work")
    assert_equal nil, tracer.current_span
    assert_equal nil, tracer.trace_id
    assert_equal nil, tracer.traceparent
  end

  # With tracing off, in_span yields a no-op span, keeps the block value, and
  # leaves no current span behind.
  def test_off_in_span_yields_a_noop_span
    tracer = Snails::Tracer.new
    result = tracer.in_span("app.work") do |span|
      assert_equal false, span.recording?
      span.set_attribute("ignored", 1)
      span.add_event("ignored")
      span.set_status(:ok)
      42
    end

    assert_equal 42, result
    assert_equal nil, tracer.current_span
  end

  # A transport must answer deliver; nil turns tracing off for later spans.
  def test_transport_setter_rejects_an_invalid_value
    tracer = Snails::Tracer.new
    message = assert_argument_error(-> { tracer.transport = Object.new })
    assert_equal true, message.include?("answering deliver")

    capture = CaptureTransport.new
    tracer.transport = capture
    assert_equal true, tracer.enabled?
    assert_equal capture, tracer.transport

    tracer.transport = nil
    assert_equal false, tracer.enabled?
    assert_equal nil, tracer.start_span("app.work")
  end

  # A turned-on in_span returns the block value and closes its span.
  def test_in_span_returns_the_block_value
    tracer = new_tracer
    result = tracer.in_span("app.work") do |span|
      assert_equal true, span.recording?
      42
    end

    assert_equal 42, result
    assert_equal nil, tracer.current_span
  end

  # An exception becomes an error status and an exception event, then reaches
  # the caller unchanged; the finished span is no longer recording.
  def test_in_span_records_an_exception_and_reraises
    tracer = new_tracer
    span = nil
    begin
      tracer.in_span("app.fail") do |current|
        span = current
        raise "boom"
      end
    rescue StandardError => failure
      assert_equal "boom", failure.message
    end

    assert_equal false, span.recording?
    assert_equal true, span.finished?
    assert_equal :error, span.status
    events = span.events
    assert_equal 1, events.length
    assert_equal "exception", events[0]["name"]
    assert_equal "RuntimeError", events[0]["attributes"]["exception.type"]
    assert_equal "boom", events[0]["attributes"]["exception.message"]
    assert_equal nil, tracer.current_span
  end

  # Sample rate 0.0 starts no trace and yields a no-op span.
  def test_zero_sample_rate_starts_no_trace
    tracer = new_tracer
    tracer.sample_rate = 0.0

    assert_equal nil, tracer.start_span("app.work")
    assert_equal nil, tracer.current_span
    result = tracer.in_span("app.work") do |span|
      assert_equal false, span.recording?
      7
    end
    assert_equal 7, result
  end

  # A sampled-out root keeps its decision: a nested span does not start a
  # fresh trace even when the rate changes mid-block.
  def test_sampled_out_root_keeps_its_decision
    tracer = new_tracer
    tracer.sample_rate = 0.0
    tracer.in_span("outer") do |outer|
      assert_equal false, outer.recording?
      tracer.sample_rate = 1.0
      tracer.in_span("inner") do |inner|
        assert_equal false, inner.recording?
      end
    end

    assert_equal nil, tracer.current_span
  end

  # A parent and child share the trace; the child's parent id is the parent
  # span, and finishing restores the parent as current.
  def test_root_and_child_spans_share_the_trace
    tracer = new_tracer
    root = tracer.start_span("GET /posts/:id", kind: :server)

    assert_equal 32, root.trace_id.length
    assert_equal 16, root.span_id.length
    assert_equal true, root.trace_id.match?(/\A[0-9a-f]{32}\z/)
    assert_equal true, root.span_id.match?(/\A[0-9a-f]{16}\z/)
    assert_equal nil, root.parent_span_id
    assert_equal :server, root.kind
    assert_equal true, root.recording?
    assert_equal root, tracer.current_span

    child = tracer.start_span("db.posts.find", kind: :client)
    assert_equal root.trace_id, child.trace_id
    assert_equal root.span_id, child.parent_span_id
    assert_equal child, tracer.current_span

    child.finish
    assert_equal root, tracer.current_span
    root.finish
    assert_equal nil, tracer.current_span
  end

  # The current span supplies trace_id and a W3C traceparent; both disappear
  # after finish.
  def test_traceparent_reflects_the_current_span
    tracer = new_tracer
    root = tracer.start_span("GET /up", kind: :server)
    expected = "00-" + root.trace_id + "-" + root.span_id + "-01"

    assert_equal expected, tracer.traceparent
    assert_equal root.trace_id, tracer.trace_id

    root.finish
    assert_equal nil, tracer.traceparent
    assert_equal nil, tracer.trace_id
  end

  # An inbound sampled=false trace records nothing; sampled=true continues
  # that trace, while a local 0.0 rate still rejects it.
  def test_parent_sampled_flag_is_followed
    tracer = new_tracer
    Snails::Tracer::Context.begin_trace(TRACE_ID, SPAN_ID, false, nil)
    assert_equal nil, tracer.start_span("GET /posts")

    Snails::Tracer::Context.end_trace
    Snails::Tracer::Context.begin_trace(TRACE_ID, SPAN_ID, true, "vendor=value")
    span = tracer.start_span("GET /posts")
    assert_equal TRACE_ID, span.trace_id
    assert_equal SPAN_ID, span.parent_span_id
    assert_equal "vendor=value", Snails::Tracer::Context.tracestate
    span.finish

    Snails::Tracer::Context.end_trace
    Snails::Tracer::Context.begin_trace(TRACE_ID, SPAN_ID, true, nil)
    tracer.sample_rate = 0.0
    assert_equal nil, tracer.start_span("GET /posts")
    Snails::Tracer::Context.end_trace
  end

  # The mode decides the default rate: development and test record every
  # trace, staging and production record one in ten.
  def test_sample_rate_defaults_by_mode
    tracer = Snails::Tracer.new
    original = Snails.env.name
    begin
      Snails.env = "test"
      assert_equal 1.0, tracer.sample_rate
      Snails.env = "development"
      assert_equal 1.0, tracer.sample_rate
      Snails.env = "staging"
      assert_equal 0.1, tracer.sample_rate
      Snails.env = "production"
      assert_equal 0.1, tracer.sample_rate
    ensure
      Snails.env = original
    end
  end

  # The setter accepts 0.0 and 1.0 (also as Integers) and rejects values
  # outside the range or outside the number types.
  def test_sample_rate_setter_validates_the_range
    tracer = Snails::Tracer.new
    tracer.sample_rate = 0.0
    assert_equal 0.0, tracer.sample_rate
    tracer.sample_rate = 1
    assert_equal 1.0, tracer.sample_rate

    message = assert_argument_error(-> { tracer.sample_rate = 1.5 })
    assert_equal true, message.include?("between 0.0 and 1.0")
    message = assert_argument_error(-> { tracer.sample_rate = "0.5" })
    assert_equal true, message.include?("number")
  end

  # A root's ratio comes from its trace id; a parent decision wins over the
  # ratio.
  def test_sampler_uses_the_trace_id_ratio
    sampler = Snails::Tracer::Sampler.new(0.5)
    low = "00000000000000000000000000000001"
    high = "ffffffffffffffffffffffffffffffff"

    assert_equal true, sampler.sample?(low, nil)
    assert_equal false, sampler.sample?(high, nil)
    assert_equal true, sampler.sample?(high, true)
    assert_equal false, sampler.sample?(low, false)
  end

  # Finished spans wait in the tracer buffer; flush hands them over as one
  # batch.
  def test_flush_hands_finished_spans_to_the_transport
    tracer = new_tracer
    capture = tracer.transport
    tracer.in_span("outer") do
      tracer.in_span("inner") do
      end
    end

    assert_equal 0, capture.batches.length
    tracer.flush
    assert_equal 1, capture.batches.length
    assert_equal 2, capture.batches[0].length
  end

  # A span keeps its name, scalar attributes, events, and status until
  # finish; a status message is valid only with :error, and a setter after
  # finish raises.
  def test_span_records_attributes_events_and_status
    tracer = new_tracer
    span = tracer.start_span("checkout.charge")

    assert_equal nil, span.end_time
    assert_equal :unset, span.status
    assert_equal 0, span.attributes.length
    assert_equal 0, span.links.length
    assert_equal 0, span.events.length

    span.set_name("checkout.charge")
    span.set_attribute("order.id", 42)
    span.set_attribute("payment.provider", "stripe")
    span.set_attribute("retry", true)
    span.add_event("payment.attempt", attributes: { "attempt" => 1 })
    span.set_status(:ok)

    assert_equal "checkout.charge", span.name
    assert_equal 42, span.attributes["order.id"]
    assert_equal "stripe", span.attributes["payment.provider"]
    assert_equal true, span.attributes["retry"]
    assert_equal 1, span.events.length
    assert_equal "payment.attempt", span.events[0]["name"]
    assert_equal 1, span.events[0]["attributes"]["attempt"]
    assert_equal :ok, span.status
    assert_equal nil, span.status_message

    message = assert_argument_error(-> { span.set_status(:ok, message: "charged") })
    assert_equal true, message.include?("only valid with :error")
    span.set_status(:error, message: "failed")
    assert_equal :error, span.status
    assert_equal "failed", span.status_message

    span.finish
    assert_equal true, span.finished?
    assert_equal true, span.end_time.is_a?(Time)
    message = assert_argument_error(-> { span.set_attribute("late", 1) })
    assert_equal true, message.include?("finished")
  end

  # A finished span cannot be closed twice, so an ensure cannot move its end
  # time.
  def test_span_finish_is_idempotent
    span = new_tracer.start_span("app.work")
    span.finish
    end_time = span.end_time
    span.finish

    assert_equal true, span.finished?
    assert_equal end_time, span.end_time
  end

  # The span constructor rejects malformed W3C ids, an unknown kind, and an
  # empty name.
  def test_span_rejects_invalid_ids_and_kinds
    message = assert_argument_error(-> { build_span(trace_id: ZERO_TRACE_ID) })
    assert_equal true, message.include?("all zero")

    message = assert_argument_error(-> { build_span(span_id: ZERO_SPAN_ID) })
    assert_equal true, message.include?("all zero")

    message = assert_argument_error(-> { build_span(trace_id: "not-hex") })
    assert_equal true, message.include?("32 lowercase hex")

    message = assert_argument_error(-> { build_span(kind: :bogus) })
    assert_equal true, message.include?("kind")

    message = assert_argument_error(-> { build_span(name: "") })
    assert_equal true, message.include?("name")
  end

  # Attributes accept only the scalar types OTLP JSON carries in this stage;
  # an unsupported key or value raises instead of being dropped.
  def test_span_rejects_invalid_attributes
    tracer = new_tracer
    message = assert_argument_error(-> {
      tracer.start_span("app.work", attributes: { "bad" => nil })
    })
    assert_equal true, message.include?("attribute bad")
    assert_equal nil, tracer.current_span

    span = tracer.start_span("app.work")
    message = assert_argument_error(-> { span.set_attribute("", "x") })
    assert_equal true, message.include?("key")

    message = assert_argument_error(-> { span.set_attribute("bad", nil) })
    assert_equal true, message.include?("attribute bad")

    message = assert_argument_error(-> {
      span.add_event("event", attributes: { "bad" => [] })
    })
    assert_equal true, message.include?("attribute bad")
    span.finish
  end

  # Nested in_span calls make the inner span a child of the outer span and
  # restore the outer span as current after the inner block.
  def test_nested_in_span_restores_the_parent
    tracer = new_tracer
    outer_span = nil
    inner_span = nil

    tracer.in_span("outer") do |outer|
      outer_span = outer
      tracer.in_span("inner") do |inner|
        inner_span = inner
        assert_equal outer.span_id, inner.parent_span_id
      end
      assert_equal outer, tracer.current_span
    end

    assert_equal true, outer_span.finished?
    assert_equal true, inner_span.finished?
    assert_equal nil, tracer.current_span
  end

  # end_trace clears the inbound values so a reused worker thread starts from
  # no trace.
  def test_end_trace_clears_the_inbound_trace
    Snails::Tracer::Context.begin_trace(TRACE_ID, SPAN_ID, true, "vendor=value")
    assert_equal TRACE_ID, Snails::Tracer::Context.trace_id
    assert_equal SPAN_ID, Snails::Tracer::Context.parent_span_id
    assert_equal true, Snails::Tracer::Context.sampled?
    assert_equal "vendor=value", Snails::Tracer::Context.tracestate

    Snails::Tracer::Context.end_trace
    assert_equal nil, Snails::Tracer::Context.trace_id
    assert_equal nil, Snails::Tracer::Context.parent_span_id
    assert_equal false, Snails::Tracer::Context.sampled?
    assert_equal nil, Snails::Tracer::Context.tracestate
  end

  # The inbound context rejects malformed W3C ids.
  def test_context_rejects_malformed_inbound_values
    message = assert_argument_error(-> {
      Snails::Tracer::Context.begin_trace(ZERO_TRACE_ID, SPAN_ID, true, nil)
    })
    assert_equal true, message.include?("all zero")

    message = assert_argument_error(-> {
      Snails::Tracer::Context.begin_trace(TRACE_ID, ZERO_SPAN_ID, true, nil)
    })
    assert_equal true, message.include?("all zero")

    message = assert_argument_error(-> {
      Snails::Tracer::Context.begin_trace("not-hex", SPAN_ID, true, nil)
    })
    assert_equal true, message.include?("32 lowercase hex")
  end
end

FixtureRunner.run(TracerTest, [
  "test_accessor_returns_a_shared_tracer",
  "test_without_a_transport_creates_no_span",
  "test_off_in_span_yields_a_noop_span",
  "test_transport_setter_rejects_an_invalid_value",
  "test_in_span_returns_the_block_value",
  "test_in_span_records_an_exception_and_reraises",
  "test_zero_sample_rate_starts_no_trace",
  "test_sampled_out_root_keeps_its_decision",
  "test_root_and_child_spans_share_the_trace",
  "test_traceparent_reflects_the_current_span",
  "test_parent_sampled_flag_is_followed",
  "test_sample_rate_defaults_by_mode",
  "test_sample_rate_setter_validates_the_range",
  "test_sampler_uses_the_trace_id_ratio",
  "test_flush_hands_finished_spans_to_the_transport",
  "test_span_records_attributes_events_and_status",
  "test_span_finish_is_idempotent",
  "test_span_rejects_invalid_ids_and_kinds",
  "test_span_rejects_invalid_attributes",
  "test_nested_in_span_restores_the_parent",
  "test_end_trace_clears_the_inbound_trace",
  "test_context_rejects_malformed_inbound_values"
])
