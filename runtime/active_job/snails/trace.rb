# frozen_string_literal: true

# Job tracing at the ActiveJob boundary: a producer span around the enqueue
# and a consumer span around the run. The span model and trace context stay in
# `Snails::Tracer`.
#
# The file lives under `active_job/snails` because it is the Snails
# instrumentation of the job layer, not a queue adapter feature.
# `runtime/active_job.rb` controls the load order.
module ActiveJob
  # @api internal
  module Trace
    # The delivery jobs write spans and logs themselves; instrumenting them
    # would feed the pipeline it delivers to. The trace delivery class lands in
    # a later stage, so its key is named here until the class exists.
    TRACE_DELIVERY_JOB_NAME = "Snails::TraceDeliveryJob"

    # @api internal
    # Run one enqueue inside a producer span. The span becomes a child of the
    # request or job span that enqueues it. A delivery job is left alone, and
    # tracing off or a sampled-out trace yields the block without a span.
    #
    # @param job_name [String] the job's dispatch key
    # @yield the adapter enqueue call
    # @yieldreturn [Object] the adapter's return value
    # @return [Object] the block's return value
    def self.publish(job_name)
      return yield unless Snails.tracer.enabled?
      return yield if delivery_job?(job_name)

      span = Snails.tracer.start_span(
        job_name + " publish",
        kind: :producer,
        attributes: publish_attributes(job_name)
      )
      return yield if span.nil?

      begin
        result = yield
        span.set_status(:ok) if span.status == :unset
        result
      rescue Exception => failure
        span.record_exception(failure)
        raise
      ensure
        span.finish
      end
    end

    # @api internal
    # Run one job body inside a consumer span. A job run starts a new trace in
    # this stage; job context propagation is a later stage. The span carries
    # the queue wait for the database adapter when it has one.
    #
    # @param job_name [String] the job's dispatch key
    # @param id [Integer, nil] the stored job id
    # @param attempt [Integer, nil] the attempt number
    # @param wait_ms [Float, nil] time from the row's run time to this start
    # @yieldparam span [Snails::Tracer::Span, nil] the consumer span, or nil
    # @yieldreturn [Object] the block's return value
    # @return [Object] the block's return value
    def self.perform(job_name, id, attempt, wait_ms)
      return yield(nil) unless Snails.tracer.enabled?
      return yield(nil) if delivery_job?(job_name)

      # A job run is its own trace in this stage; clear any context a previous
      # unit left on the worker thread before starting the root.
      Snails::Tracer::Context.end_trace
      span = Snails.tracer.start_span(
        job_name + " process",
        kind: :consumer,
        attributes: perform_attributes(job_name, id, attempt, wait_ms)
      )
      begin
        result = yield(span)
        span.set_status(:ok) if !span.nil? && span.status == :unset
        result
      rescue Exception => failure
        span.record_exception(failure) unless span.nil?
        raise
      ensure
        span.finish unless span.nil?
        Snails::Tracer::Context.end_trace
      end
    end

    # @api internal
    # Record a failure on the consumer span before the queue records the row.
    # A nil span (tracing off, a sampled-out trace, or an excluded delivery
    # job) is left alone.
    #
    # @param span [Snails::Tracer::Span, nil] the consumer span
    # @param failure [Exception] the delivery or body failure
    # @return [void]
    def self.record_error(span, failure)
      return if span.nil?

      span.record_exception(failure)
    end

    # @api internal
    # The queue wait in milliseconds: from the row's run time, or its creation
    # time when the run was immediate, to the run's start. nil when the row has
    # neither time.
    #
    # @param scheduled_at [Time, nil] the row's run time
    # @param created_at [Time, nil] the row's creation time
    # @param started [Time] the run's start
    # @return [Float, nil] the wait in milliseconds
    def self.queue_wait_ms(scheduled_at, created_at, started)
      base = scheduled_at.nil? ? created_at : scheduled_at
      return nil if base.nil?

      (started - base) * 1000.0
    end

    def self.publish_attributes(job_name)
      {
        "messaging.system" => "snails",
        "messaging.destination.name" => job_name,
        "messaging.operation" => "publish",
        "snails.job.name" => job_name
      }
    end

    def self.perform_attributes(job_name, id, attempt, wait_ms)
      attributes = {
        "messaging.system" => "snails",
        "messaging.destination.name" => job_name,
        "messaging.operation" => "process",
        "snails.job.name" => job_name
      }
      attributes["snails.job.id"] = id unless id.nil?
      attributes["snails.job.attempt"] = attempt unless attempt.nil?
      attributes["snails.queue.wait_ms"] = wait_ms unless wait_ms.nil?
      attributes
    end

    # A delivery job writes spans or logs itself; instrumenting its enqueue or
    # run would create a feedback loop. The log delivery job already exists; the
    # trace delivery job name is reserved for the later stage.
    def self.delivery_job?(job_name)
      return true if job_name == Snails::LogDeliveryJob.name

      job_name == TRACE_DELIVERY_JOB_NAME
    end

    private_constant :TRACE_DELIVERY_JOB_NAME
    private_class_method :publish_attributes, :perform_attributes, :delivery_job?
  end
end
