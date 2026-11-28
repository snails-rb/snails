# frozen_string_literal: true

# Request tracing at the Tep HTTP boundary: adopt a valid inbound W3C
# `traceparent`, open the server span, apply the matched route, and close it
# with the HTTP status or the exception. `Tep::App#dispatch` owns the request
# lifecycle and calls these; the span model and trace context stay in
# `Snails::Tracer`.
#
# The file lives under `tep/snails` because it is the Snails instrumentation
# of the Tep server, not a Tep server feature. `runtime/tep/tep.rb` controls
# the load order.
module Tep
  module Trace
    # @api internal
    # Start the request trace: adopt an inbound `traceparent` first, then open
    # the request span. The name starts as the method and gains the route
    # pattern in `apply_route`; the path is the actual path without the query.
    #
    # @param req [Tep::Request] the parsed request
    # @return [Snails::Tracer::Span, nil] the request span, or nil when tracing
    #   is off or the trace is not sampled
    def self.start(req)
      return nil unless Snails.tracer.enabled?

      adopt(req)
      attributes = {
        "http.request.method" => req.verb,
        "url.path" => req.path
      }
      request_id = Snails::Logger::Context.request_id
      if !request_id.nil? && !request_id.empty?
        attributes["snails.request_id"] = request_id
      end
      Snails.tracer.start_span(req.verb, kind: :server, attributes: attributes)
    end

    # Apply the matched route to the request span: the low-cardinality name,
    # `http.route`, and the controller/action attributes. A route miss keeps
    # the method-only name; the request boundary still closes the span with
    # the 404 status.
    #
    # @api internal
    # @param req [Tep::Request] the parsed request
    # @param matched [ActionDispatch::Router::MatchResult] the matched route
    # @return [void]
    def self.apply_route(req, matched)
      span = Snails.tracer.current_span
      return if span.nil?

      span.set_name(req.verb + " " + matched.pattern)
      span.set_attribute("http.route", matched.pattern)
      span.set_attribute("snails.controller", matched.controller.name)
      span.set_attribute("snails.action", matched.action.to_s)
    end

    # @api internal
    # Record a failure as the 500 status and an exception event. The caller
    # logs and re-raises the same failure.
    #
    # @param span [Snails::Tracer::Span, nil] the request span
    # @param failure [Exception] the failure the request boundary rescued
    # @return [void]
    def self.record_failure(span, failure)
      return if span.nil?

      span.set_attribute("http.response.status_code", 500)
      span.record_exception(failure)
    end

    # @api internal
    # Close the request span's status: 2xx/3xx are ok, 4xx stay unset as
    # client errors, and 5xx are error.
    #
    # @param span [Snails::Tracer::Span, nil] the request span
    # @param status [Integer] the response status
    # @return [void]
    def self.record_response(span, status)
      return if span.nil?

      span.set_attribute("http.response.status_code", status)
      if status >= 500
        span.set_status(:error)
      elsif status >= 400
        span.set_status(:unset)
      else
        span.set_status(:ok)
      end
    end

    # @api internal
    # Finish the request span and clear the thread's trace context. A nil span
    # still clears an inbound context from a sampled-out trace.
    #
    # @param span [Snails::Tracer::Span, nil] the request span
    # @return [void]
    def self.finish(span)
      span.finish unless span.nil?
      Snails::Tracer::Context.end_trace
    end

    # Adopt a valid inbound W3C `traceparent`. A broken or missing header is
    # ignored, so `start` opens a new trace; `tracestate` is preserved as
    # opaque input.
    def self.adopt(req)
      header = req.req_headers["traceparent"].to_s
      return if header.empty?

      parts = header.split("-")
      return unless parts.length == 4
      return unless parts[0] == "00"

      flags = parts[3]
      return unless flags.length == 2 && hex_text?(flags)

      begin
        Snails::Tracer::Context.begin_trace(
          parts[1],
          parts[2],
          sampled_flag?(flags),
          req.req_headers["tracestate"]
        )
      rescue ArgumentError
        nil
      end
    end

    # Whether `value` is lowercase or uppercase hex text. The id validators
    # enforce lowercase for the ids; this only keeps a malformed flag byte from
    # reaching the sampled-bit check.
    def self.hex_text?(value)
      i = 0
      while i < value.length
        byte = value.getbyte(i)
        if (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102) || (byte >= 65 && byte <= 70)
          i += 1
        else
          return false
        end
      end
      true
    end

    # The least significant bit of the W3C flags byte: an odd last hex digit.
    def self.sampled_flag?(flags)
      "13579bdf".include?(flags[1, 1].to_s.downcase)
    end

    private_class_method :adopt, :hex_text?, :sampled_flag?
  end
end
