# frozen_string_literal: true

# The one OTLP/HTTP sender: endpoint/token validation, the signal path, a
# per-process session, and the retry policy. Logs and traces differ only in
# their encoder and path, so neither transport keeps its own HTTP copy.
require "net/http"
require "openssl"
require "uri"

module Snails
  module OTLP
    # The failure the sender raises for a non-2xx response. `status` is the
    # HTTP code, nil for a network-level failure.
    class DeliveryError < StandardError
      def initialize(message, status = nil)
        super(message)
        @status = status
      end

      # the HTTP status that failed, or nil for a network error.
      #
      # @return [Integer, nil]
      def status
        @status
      end
    end

    class HTTP
      # Timeouts keep a dead endpoint from holding a worker for long.
      OPEN_TIMEOUT = 2
      READ_TIMEOUT = 2

      # One retry covers a transient 5xx or a dropped connection; a 4xx is
      # permanent (bad token, malformed batch, too large) and is not retried.
      MAX_ATTEMPTS = 2

      # configure the destination. The endpoint is the receiver's base URL
      # (scheme, host, and optional path prefix); `path` is the signal path
      # appended by this helper (`v1/logs` or `v1/traces`). The token is sent as
      # `Authorization: Bearer`. All values are validated here so a typo fails
      # at boot rather than on the first batch.
      #
      # @param endpoint [String] the base `http` or `https` URL
      # @param token [String] the ingest token
      # @param path [String] the signal path under the base
      # @raise [ArgumentError] endpoint, token, or path is empty or malformed
      def initialize(endpoint:, token:, path:)
        if !endpoint.is_a?(String) || endpoint.empty?
          raise ArgumentError, "OTLP endpoint must be a non-empty String"
        end
        if !token.is_a?(String) || token.empty?
          raise ArgumentError, "OTLP token must be a non-empty String"
        end
        if !path.is_a?(String) || path.empty?
          raise ArgumentError, "OTLP path must be a non-empty String"
        end

        @token = token
        @session = nil
        @session_lock = Mutex.new
        begin
          @uri = URI.parse(signal_url(endpoint, path))
        rescue StandardError
          raise ArgumentError, "OTLP endpoint is not a valid URL: " + endpoint
        end
        if @uri.host.nil? || (@uri.scheme != "http" && @uri.scheme != "https")
          raise ArgumentError, "OTLP endpoint must be an http or https URL: " + endpoint
        end
      end

      # the resolved signal URL, for diagnostics and tests.
      #
      # @api internal
      # @return [URI] the full endpoint URL
      def url
        @uri
      end

      # drop the parent's HTTP session in a forked child. The socket and the
      # lock belong to the parent process; a child that inherited them would
      # write on a connection another process owns.
      #
      # @return [void]
      def after_fork
        close_session
        @session_lock = Mutex.new
      end

      # post one encoded OTLP batch. A 2xx succeeds; a 4xx raises immediately; a
      # 5xx or a network error is retried once.
      #
      # @param body [Hash] the OTLP JSON structure
      # @return [Boolean] true when the endpoint answered 2xx
      # @raise [DeliveryError] the endpoint refused the batch, or the retry
      #   budget was spent
      def send_encoded(body)
        attempt = 0
        while attempt < MAX_ATTEMPTS
          begin
            response = post(body)
            code = response.code.to_i
            return true if code >= 200 && code < 300
            if code >= 400 && code < 500
              raise DeliveryError.new("OTLP endpoint returned " + code.to_s, code)
            end
            if attempt + 1 >= MAX_ATTEMPTS
              raise DeliveryError.new("OTLP endpoint returned " + code.to_s, code)
            end
          rescue DeliveryError
            raise
          rescue StandardError
            raise if attempt + 1 >= MAX_ATTEMPTS
          end
          attempt = attempt + 1
        end
        raise DeliveryError.new("OTLP endpoint did not accept the batch")
      end

      private

      # The signal URL for a base endpoint. A trailing slash is absorbed, so a
      # base with or without one addresses the same signal URL; a base path
      # prefix is preserved.
      def signal_url(base, path)
        if base.end_with?("/")
          base + path
        else
          base + "/" + path
        end
      end

      # One HTTP request. A single process keeps one `Net::HTTP` session open:
      # batches arrive about once a second, so a new TCP/TLS handshake per
      # batch is waste. `Net::HTTP` reuses the connection while both sides
      # keep it alive and reconnects when the server closed it; a failed
      # request drops the session here so the retry opens a fresh one.
      def post(body)
        request = Net::HTTP::Post.new(@uri)
        request["Authorization"] = "Bearer " + @token
        request["Content-Type"] = "application/json"
        request.body = JSON.generate(body)
        @session_lock.synchronize do
          begin
            session.request(request)
          rescue StandardError
            close_session
            raise
          end
        end
      end

      # The started session for this process. It is created on first use so a
      # process that never sends never opens a socket.
      def session
        if @session.nil?
          http = Net::HTTP.new(@uri.host, @uri.port)
          http.use_ssl = @uri.scheme == "https"
          http.open_timeout = OPEN_TIMEOUT
          http.read_timeout = READ_TIMEOUT
          http.start
          @session = http
        end
        @session
      end

      # Close the session after a failed request or in a forked child. A
      # server-side close is not an error: `finish` may raise when the socket
      # is already gone, and the next request opens a new session.
      def close_session
        http = @session
        @session = nil
        return if http.nil?
        begin
          http.finish
        rescue StandardError
          nil
        end
      end
    end
  end
end
