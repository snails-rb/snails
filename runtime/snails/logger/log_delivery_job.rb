# frozen_string_literal: true

# the HTTP half of log delivery. The default transport encodes a batch and
# enqueues this job; the job posts the batch and reports a failure locally. The
# queue writes this job's `job.*` records like any other, and the record writer
# drops them (`Context.job_events_suppressed?`) — those records would themselves
# be delivered, enqueueing another delivery job.
module Snails
  class LogDeliveryJob < ActiveJob::Base
    # post one encoded OTLP batch. The transport is read at run time so a
    # swapped transport is honored; a missing transport or a network/HTTP
    # failure is written locally and, for a real failure, raised to the queue so
    # the row records it.
    #
    # @param body [Hash] the OTLP logs JSON structure
    # @return [void]
    # @raise [StandardError] the transport failure after the local report
    def self.perform(body)
      transport = Snails.logger.transport
      if transport.nil? || !transport.respond_to?(:send_encoded)
        Snails.logger.report_local(:warn, "[logger] log delivery skipped: no OTLP transport")
        return
      end

      begin
        transport.send_encoded(body)
      rescue StandardError => failure
        Snails.logger.report_local(
          :error,
          "[logger] log delivery failed: " + failure.class.to_s + ": " + failure.message
        )
        raise
      end
    end
  end
end
