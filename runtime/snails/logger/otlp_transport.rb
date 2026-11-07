# frozen_string_literal: true

# `Snails::Logger::OTLPTransport` — the default transport: turn one batch of
# `Record`s into OTLP logs JSON and hand it to `Snails::LogDeliveryJob`. The
# HTTP call runs in the job, so a slow or dead log service never blocks a
# request thread. The endpoint is the receiver's base URL; the transport
# appends the OTLP logs path (`v1/logs`) itself, so an app configures one
# receiver address and does not duplicate the signal path. The endpoint and
# token stay in this object, not in the job payload, so a store-backed queue
# never persists the token.
#
# `send_encoded(body)` is the job's half: it posts the already-encoded batch
# and turns a 4xx into a permanent failure, retrying a 5xx or a network error
# once. The job reports the final failure locally.
require "net/http"
require "openssl"
require "securerandom"
require "uri"

module Snails
  class Logger
    class OTLPTransport
      # Timeouts keep a dead endpoint from holding a worker for long.
      OPEN_TIMEOUT = 2
      READ_TIMEOUT = 2

      # One retry covers a transient 5xx or a dropped connection; a 4xx is
      # permanent (bad token, malformed batch, too large) and is not retried.
      MAX_ATTEMPTS = 2

      # The failure `send_encoded` raises for a non-2xx response. `status` is
      # the HTTP code, nil for a network-level failure.
      class DeliveryError < StandardError
        def initialize(message, status = nil)
          super(message)
          @status = status
        end

        # `status()` — the HTTP status that failed, or nil for a network error.
        #
        # @return [Integer, nil]
        def status
          @status
        end
      end

      # `initialize(endpoint:, token:)` — configure the destination. The
      # endpoint is the receiver's base URL (scheme, host, and optional path
      # prefix); the transport appends the OTLP logs path itself. A trailing
      # slash on the base is absorbed. The token is sent as
      # `Authorization: Bearer`. Both are validated here so a typo fails at
      # boot rather than on the first batch.
      #
      # @param endpoint [String] the base `http` or `https` URL
      # @param token [String] the ingest token
      # @raise [ArgumentError] endpoint or token is empty or malformed
      def initialize(endpoint:, token:)
        if !endpoint.is_a?(String) || endpoint.empty?
          raise ArgumentError, "OTLPTransport endpoint must be a non-empty String"
        end
        if !token.is_a?(String) || token.empty?
          raise ArgumentError, "OTLPTransport token must be a non-empty String"
        end

        @endpoint = endpoint
        @token = token
        @executor_warned = false
        @session = nil
        @session_lock = Mutex.new
        begin
          @uri = URI.parse(logs_url(endpoint))
        rescue StandardError
          raise ArgumentError, "OTLPTransport endpoint is not a valid URL: " + endpoint
        end
        if @uri.host.nil? || (@uri.scheme != "http" && @uri.scheme != "https")
          raise ArgumentError, "OTLPTransport endpoint must be an http or https URL: " + endpoint
        end
      end

      # `after_fork()` — drop the parent's HTTP session in a forked child.
      # The socket and the lock belong to the parent process; a child that
      # inherited them would write on a connection another process owns.
      #
      # @return [void]
      def after_fork
        close_session
        @session_lock = Mutex.new
      end

      # `deliver(records)` — encode one batch and enqueue the delivery job. It
      # never performs HTTP; the transport contract stays the hand-off point.
      #
      # A process without a registered executor would run the job at the call
      # site and block the caller, so that case is refused. The first refusal
      # is reported to the logger; later batches stay local without repeating
      # the warning.
      #
      # @param records [Array<Record>] the buffered records
      # @return [void]
      # @raise [RuntimeError] no executor is registered, on the first batch
      def deliver(records)
        return nil if records.length == 0
        if !ActiveJob.executor_registered
          if !@executor_warned
            @executor_warned = true
            raise "log delivery needs a registered ActiveJob executor"
          end
          return nil
        end

        body = encode(records, new_batch_id)
        ActiveJob.enqueue(Snails::LogDeliveryJob, body)
      end

      # `send_encoded(body)` — post one encoded OTLP batch. A 2xx succeeds; a
      # 4xx raises immediately; a 5xx or a network error is retried once.
      #
      # @param body [Hash] the OTLP logs JSON structure
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
              raise DeliveryError.new("log endpoint returned " + code.to_s, code)
            end
            if attempt + 1 >= MAX_ATTEMPTS
              raise DeliveryError.new("log endpoint returned " + code.to_s, code)
            end
          rescue DeliveryError
            raise
          rescue StandardError
            raise if attempt + 1 >= MAX_ATTEMPTS
          end
          attempt = attempt + 1
        end
        raise DeliveryError.new("log endpoint did not accept the batch")
      end

      private

      # The OTLP logs URL for a base endpoint. OTLP/HTTP defines `v1/logs`
      # as the default logs path under a base endpoint; a receiver with a
      # non-default path needs the signal-specific full URL, which this
      # transport does not model yet. A trailing slash is absorbed, so a base
      # with or without one addresses the same logs URL; a base path prefix
      # is preserved.
      def logs_url(base)
        path = "v1/logs"
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
      # process that never logs never opens a socket.
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

      # The OTLP envelope for one batch. All records in a batch share the
      # process resource; the first record's bag is the batch's resource.
      def encode(records, batch_id)
        first = records[0]
        log_records = []
        seq = 0
        records.each do |record|
          log_records << log_record(record, batch_id, seq)
          seq = seq + 1
        end
        {
          "resourceLogs" => [
            {
              "resource" => { "attributes" => attributes(first.resource) },
              "scopeLogs" => [
                {
                  "scope" => { "name" => "snails.logger" },
                  "logRecords" => log_records
                }
              ]
            }
          ]
        }
      end

      def log_record(record, batch_id, seq)
        attributes_out = [
          { "key" => "event.name", "value" => { "stringValue" => record.event } }
        ]
        append_attributes(attributes_out, record.fields)
        type = record.exception_type
        if !type.nil?
          attributes_out << { "key" => "exception.type", "value" => { "stringValue" => type } }
        end
        exception_message = record.exception_message
        if !exception_message.nil?
          attributes_out << { "key" => "exception.message", "value" => { "stringValue" => exception_message } }
        end
        stacktrace = record.exception_stacktrace
        if !stacktrace.nil?
          attributes_out << { "key" => "exception.stacktrace", "value" => { "stringValue" => stacktrace } }
        end
        attributes_out << { "key" => "snails.batch_id", "value" => { "stringValue" => batch_id } }
        attributes_out << { "key" => "snails.seq", "value" => { "intValue" => seq.to_s } }
        {
          "timeUnixNano" => time_unix_nano(record.time),
          "severityNumber" => severity_number(record.severity),
          "severityText" => record.severity.to_s.upcase,
          "body" => { "stringValue" => record.body },
          "attributes" => attributes_out
        }
      end

      def append_attributes(out, fields)
        fields.each do |name, value|
          any = any_value(value)
          out << { "key" => name, "value" => any } unless any.nil?
        end
      end

      def attributes(fields)
        out = []
        append_attributes(out, fields)
        out
      end

      # OTLP AnyValue: strings, ints, doubles, and booleans. nil is omitted so
      # the receiver never has to interpret a null attribute.
      def any_value(value)
        if value.is_a?(String)
          { "stringValue" => value }
        elsif value.is_a?(Integer)
          { "intValue" => value.to_s }
        elsif value.is_a?(Float)
          { "doubleValue" => value }
        elsif value == true || value == false
          { "boolValue" => value }
        end
      end

      # The OTLP backend stores microseconds; the last three digits are the
      # precision the record's Time carries.
      def time_unix_nano(time)
        (time.to_i * 1000000000 + time.usec * 1000).to_s
      end

      def severity_number(severity)
        case severity
        when :debug then 5
        when :info then 9
        when :warn then 13
        when :error then 17
        when :fatal then 21
        else
          raise ArgumentError, "unknown log severity: " + severity.to_s
        end
      end

      # Per batch, not per process: a forked child or a retried batch must not
      # share an id with another batch.
      def new_batch_id
        Process.pid.to_s + "-" + SecureRandom.hex(8)
      end
    end
  end
end
