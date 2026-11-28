# frozen_string_literal: true

# The traces OTLP transport: encode spans and hand the JSON to the shared
# HTTP helper. The span batch/job stage owns `deliver`; this stage owns the
# endpoint, the `v1/traces` path, and the encoder handoff.
#
# endpoint and token stay out of the batch payload; the HTTP helper owns the
# session, retry, and auth contract.
module Snails
  class Tracer
    class OTLPTransport
      # The failure `send_encoded` raises for a non-2xx response. The shared
      # HTTP helper raises `Snails::OTLP::DeliveryError`; the transport keeps
      # its own class so a tracer error and a logs error stay distinguishable.
      class DeliveryError < Snails::OTLP::DeliveryError
      end

      # configure the destination. The endpoint is the receiver's base URL
      # (scheme, host, and optional path prefix); the shared helper appends the
      # OTLP traces path. A trailing slash on the base is absorbed. The token is
      # sent as `Authorization: Bearer`. Both are validated here so a typo fails
      # at boot rather than on the first batch.
      #
      # @param endpoint [String] the base `http` or `https` URL
      # @param token [String] the ingest token
      # @raise [ArgumentError] endpoint or token is empty or malformed
      def initialize(endpoint:, token:)
        @executor_warned = false
        @http = Snails::OTLP::HTTP.new(endpoint: endpoint, token: token, path: "v1/traces")
      end

      # the resolved traces URL, for diagnostics and tests.
      #
      # @api internal
      # @return [URI] the full endpoint URL
      def url
        @http.url
      end

      # drop the parent's HTTP session in a forked child.
      #
      # @return [void]
      def after_fork
        @http.after_fork
      end

      # Encode one finished span batch and enqueue `TraceDeliveryJob`; the
      # request/job thread never performs HTTP. A process without a registered
      # executor would run the job at the call site, so that case is refused;
      # the first refusal raises and later batches stay local without repeating
      # the warning.
      #
      # @param spans [Array<Snails::Tracer::Span>] the finished spans
      # @return [void]
      # @raise [RuntimeError] no executor is registered, on the first batch
      def deliver(spans)
        return nil if spans.length == 0
        if !ActiveJob.executor_registered
          if !@executor_warned
            @executor_warned = true
            raise "trace delivery needs a worker loop"
          end
          return nil
        end

        body = encode(spans)
        ActiveJob.enqueue(Snails::TraceDeliveryJob, body)
      end

      # encode one finished span batch as OTLP traces JSON. The delivery job
      # calls `send_encoded`; the resource is read at encode time so an
      # app/environment change applies to the next batch.
      #
      # @api internal
      # @param spans [Array<Snails::Tracer::Span>] the finished spans
      # @return [Hash{String => Object}] the OTLP traces JSON structure
      def encode(spans)
        Snails::Tracer::OTLPEncoder.encode(
          spans,
          Snails.tracer.resource_attributes,
          Snails.version
        )
      end

      # post one encoded OTLP batch. The shared helper owns the 4xx/5xx and
      # network retry contract; the transport maps its error class back to the
      # tracer class.
      #
      # @param body [Hash] the OTLP traces JSON structure
      # @return [Boolean] true when the endpoint answered 2xx
      # @raise [DeliveryError] the endpoint refused the batch, or the retry
      #   budget was spent
      def send_encoded(body)
        begin
          @http.send_encoded(body)
        rescue Snails::OTLP::DeliveryError => failure
          raise DeliveryError.new(failure.message, failure.status)
        end
      end
    end
  end
end
