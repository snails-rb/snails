# Tep::App — the per-process singleton holding the fan-out registries and
# scheduler state shared by connection threads. `dispatch` leases a pooled DB
# connection and calls `Snails::Main.dispatch`.
#
# Broadcast registry reads and writes all take `broadcast_lock`.
module Tep
  class App
    # the Tep::Broadcast registry: each entry pairs a topic with an output fd
    # and a delivery mode. `broadcast_lock` is the mutex every reader and writer
    # takes, because the connection threads share this object.
    #
    # @return [Array<Tep::BroadcastSubscription>, Mutex] `broadcast_subs`,
    #   then `broadcast_lock`
    attr_accessor :broadcast_subs, :broadcast_lock

    # Cooperative-scheduler state (Tep::Scheduler, which only the
    # measurement-only server drives). One entry per fiber across these
    # parallel arrays:
    #   sched_fibers   PtrArray<FiberSlot>  the Fiber
    #   sched_wake_at  IntArray             monotonic µs; -1 = ready now
    #   sched_io_fd    IntArray             fd parked on; -1 = none
    #   sched_io_mode  IntArray             requested mode bits (1=R,2=W)
    #   sched_io_ready IntArray             observed-ready bits (0=not yet)
    attr_accessor :sched_fibers, :sched_wake_at, :sched_current
    attr_accessor :sched_io_fd, :sched_io_mode, :sched_io_ready

    # the app's own name for the startup banner and the log prefix
    # (`Tep.display_name`). Assigned by `Snails::Main.start` before the server
    # runs; empty until then.
    #
    # @return [String] the app name, or "" until the server assigns it
    attr_accessor :name

    def initialize
      @name = ""
      # Type-seed the Broadcast subscriber registry: one push seeds the
      # element type, then it is dropped.
      @broadcast_subs = [Tep::BroadcastSubscription.new(
        "_", -1, 0, Tep::WebSocket::Driver.new(-1))]
      @broadcast_subs.pop
      @broadcast_lock = Mutex.new

      # Scheduler arrays (fiber mode): seed a noop-bodied entry to fix each
      # element type, then drop it.
      @sched_fibers   = [Tep::FiberSlot.new(Fiber.new { Tep.seed_fiber_noop })]
      @sched_fibers.pop
      @sched_wake_at  = [0]
      @sched_wake_at.pop
      @sched_current  = -1               # currently-running fiber index
      @sched_io_fd    = [0]
      @sched_io_fd.pop
      @sched_io_mode  = [0]
      @sched_io_mode.pop
      @sched_io_ready = [0]
      @sched_io_ready.pop
    end

    # the per-request entry point: every server calls
    # `Tep::APP.dispatch(req, res)` because the handler runs as a class method
    # and cannot hold instance state.
    #
    # The request lease scope and the request log share this seam because every
    # request passes through it: the scope checks a pooled connection out on
    # the first database access (a request that never reaches the database,
    # such as `/up`, never touches the pool), switches on the per-request query
    # cache at that checkout, and releases at the boundary; the log writes one
    # `request.completed` record at info after the scope closes. A raised
    # unit failure or a returned 5xx writes one `request.failed` error record
    # (status, duration, and exception when raised) and a raised failure is
    # re-raised for the server's 500; control and fatal exceptions leave the
    # boundary without a record. The request id is minted here so the record
    # and any app line share it, and it is not cleared on the way out.
    #
    # This seam also frames HTTP HEAD: a HEAD request leaves `res.headers_only`
    # set, and the write paths send that response's status and headers —
    # Content-Length computed from the body — with no message body. Deciding
    # here rather than in each write path keeps the rule in one place; a client
    # reads no body from a HEAD response, so bytes written anyway would be
    # taken for the next response on a keep-alive connection.
    #
    # @param req [Tep::Request] the request Parser.parse built
    # @param res [Tep::Response] the response the action writes into
    # @return [void]
    def dispatch(req, res)
      res.headers_only = true if req.verb == "HEAD"
      Snails::Logger::Context.begin_request
      started = Sock.sphttp_now_us
      # A CORS preflight is answered before routing, auth, and the DB scope.
      # The browser sends no credentials on it, so no app filter may see it.
      if Snails::Cors.preflight(req, res)
        log_request_completed(req, started, res.status)
        return
      end
      # Actual-response headers go on before the app runs, so a 404, 400, or
      # 401 the dispatch builds still carries them.
      Snails::Cors.apply(req, res)
      continue_inbound_trace(req)
      span = start_request_span(req)
      begin
        begin
          Sqlx::Database.with_connection { Snails::Main.dispatch(req, res) }
        rescue Exception => failure
          raise if Snails::ErrorBoundary.fatal?(failure)
          record_request_failure(span, failure)
          log_request_failed(req, started, 500, failure)
          raise
        end
        # The app may have replaced Vary; merge the origin value again rather
        # than let a controller drop it.
        Snails::Cors.apply(req, res)
        record_request_response(span, res.status)
        if res.status >= 500
          log_request_failed(req, started, res.status, nil)
        else
          log_request_completed(req, started, res.status)
        end
      ensure
        span.finish unless span.nil?
        Snails::Tracer::Context.end_trace
      end
    end

    # Adopt a valid inbound W3C `traceparent` before the request span starts.
    # A broken or missing header is ignored, so `start_request_span` starts a
    # new trace; `tracestate` is preserved as opaque input.
    def continue_inbound_trace(req)
      return unless Snails.tracer.enabled?

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

    # Open the request span. The name starts as the method and gains the route
    # pattern in `Snails::Main.dispatch`; the path is the actual path without
    # the query string.
    def start_request_span(req)
      return nil unless Snails.tracer.enabled?

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

    def record_request_failure(span, failure)
      return if span.nil?

      span.set_attribute("http.response.status_code", 500)
      span.record_exception(failure)
    end

    # Close the request span's status: 2xx/3xx are ok, 4xx stay unset as client
    # errors, and 5xx are error. The request log uses the same 500 line.
    def record_request_response(span, status)
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

    # Whether `value` is lowercase or uppercase hex text. The id validators
    # enforce lowercase for the ids; this only keeps a malformed flag byte from
    # reaching the sampled-bit check.
    def hex_text?(value)
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
    def sampled_flag?(flags)
      "13579bdf".include?(flags[1, 1].to_s.downcase)
    end

    # the one info record a served request leaves. The matched controller/action
    # and request id come from `Snails::Logger::Context`; a request that never
    # reached a controller (404, 400, or an app dispatch that does not record
    # them) simply omits those fields.
    def log_request_completed(req, started, status)
      Snails.logger.info(
        request_summary(req, status),
        event: "request.completed",
        fields: request_fields(req, started, status)
      )
    end

    # the one error record a failed request leaves. A raised exception and a 5xx
    # response both land here; the exception is nil for a returned 5xx. The
    # exception travels on the record, so a transport receives the type,
    # message, and stacktrace together with the status and duration.
    def log_request_failed(req, started, status, failure)
      Snails.logger.error(
        request_summary(req, status),
        event: "request.failed",
        fields: request_fields(req, started, status),
        exception: failure
      )
    end

    # The human half of both request records: one line naming the request and
    # its status, so a terminal reader does not need the field bag.
    def request_summary(req, status)
      req.verb + " " + req.path + " " + status.to_s
    end

    # Both events share the field vocabulary: method, path, status, a numeric
    # duration in milliseconds, and the DB time the adapter accumulated.
    # `snails.db_ms` is a subset of duration, not its remainder — routing,
    # JSON rendering, and the SQLite lease sit outside the DB entries.
    def request_fields(req, started, status)
      microseconds = Sock.sphttp_now_us - started
      db_us = Snails::Logger::Context.db_us
      fields = {
        "http.request.method" => req.verb,
        "url.path" => req.path,
        "http.response.status_code" => status,
        "snails.duration_ms" => microseconds / 1000.0,
        "snails.db_ms" => db_us / 1000.0
      }
      format = Snails::Logger::Context.format
      fields["snails.format"] = format if !format.nil? && !format.empty?
      fields
    end

    private :continue_inbound_trace, :start_request_span
    private :record_request_failure, :record_request_response
    private :hex_text?, :sampled_flag?
    private :log_request_completed, :log_request_failed, :request_summary, :request_fields
  end

  APP = App.new
end
