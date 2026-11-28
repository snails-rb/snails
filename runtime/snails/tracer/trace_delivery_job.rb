# frozen_string_literal: true

# the HTTP half of trace delivery. The OTLP transport encodes a batch and
# enqueues this job; the job posts the batch and reports a failure locally. The
# queue writes this job's `job.*` records like any other; automatic job spans
# exclude it (`ActiveJob::Trace.delivery_job?`), so the trace delivery cannot
# create another trace delivery.
module Snails
  class TraceDeliveryJob < ActiveJob::Base
    # post one encoded OTLP batch. The transport is read at run time so a
    # swapped transport is honored; a missing transport or a network/HTTP
    # failure is written locally and, for a real failure, raised to the queue so
    # the row records it.
    #
    # @param body [Hash] the OTLP traces JSON structure
    # @return [void]
    # @raise [StandardError] the transport failure after the local report
    def self.perform(body)
      transport = Snails.tracer.transport
      if transport.nil? || !transport.respond_to?(:send_encoded)
        Snails.logger.report_local(:warn, "[tracer] trace delivery skipped: no OTLP transport")
        return
      end

      begin
        transport.send_encoded(body)
      rescue StandardError => failure
        Snails.logger.report_local(
          :error,
          "[tracer] trace delivery failed: " + failure.class.to_s + ": " + failure.message
        )
        raise
      end
    end
  end
end
