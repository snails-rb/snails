# Tep::Server::Scheduled -- fiber-per-connection HTTP server over cooperative
# I/O (`Tep::Scheduler` + sp_net non-blocking accept/recv). A measurement-only
# server: the app entry never selects it, and the harness covers it only
# through its write path and the scheduler. The code stays for the 2.0
# concurrency model.
#
# Keep-alive HTTP only: a WebSocket upgrade gets 501, since its recv loop needs
# a parked green thread and would hold every other connection here. All fibers
# also share the main thread, so per-request `Thread.current` state is not
# isolated across connections — the request lease, log context, and query
# cache all assume one request per thread.
module Tep
  class Server
    class Scheduled
      # Cap on one request's start-line + headers, in bytes (64 KiB).
      MAX_REQUEST_BYTES = 65535

      # Idle keep-alive timeout between requests on one connection, in seconds.
      KEEPALIVE_TIMEOUT = 30

      # listen and serve, one fiber per connection on the cooperative scheduler.
      # A port already in use stops the process with exit(1); `workers` above
      # one preforks that many servers of the same shape; `quiet` only
      # suppresses the banner. Nothing in the app entry calls this: a
      # measurement run constructs the server and invokes it directly.
      #
      # @param port [Integer] the port to bind
      # @param workers [Integer] server process count; above one, prefork
      # @param quiet [Boolean] true to skip the startup banner
      # @return [void] the prefork parent returns after its children are
      #   reaped; a single-process server exits instead
      def run(port, workers, quiet)
        @port = port
        @workers = workers
        sfd = Sock.sphttp_listen(port, workers > 1 ? 1 : 0)
        if sfd < 0
          # Loud + nonzero exit: the one plausible cause on a sane host is
          # another process bound to the port, and a quiet return made the
          # binary look like it started and immediately vanished.
          $stderr.puts Tep.display_name + ": cannot bind to port " +
                       port.to_s + " (already in use?)"
          exit(1)
        end
        Sock.sphttp_set_nonblock(sfd)
        if !quiet
          # Printed only after a successful bind, so startup and bind failure
          # are distinguishable at a glance. Explicit flush: when stdout is
          # redirected (not a TTY) C stdio block-buffers, and a banner that only
          # shows up at exit is no banner at all.
          puts Tep.display_name + " (" + RUBY_ENGINE +
               ") listening on http://0.0.0.0:" + port.to_s +
               ", pid " + Sock.sphttp_getpid.to_s
          puts "  one fiber per connection (measurement only); OS workers: " +
               "1, the main thread; processes: " + Tep.processes_desc(workers)
          $stdout.flush
        end

        # Install SIGTERM/SIGINT handlers before fork so children inherit them;
        # the loops below poll the flag and run Tep.on_shutdown on the way out.
        Sock.sphttp_install_term_handlers

        if workers > 1
          i = 0
          while i < workers
            pid = Sock.sphttp_fork
            if pid == 0
              # The child owns the logger the fork copied: the parent's
              # buffered records would be sent by every child, and the
              # inherited write lock may be held by a thread that does not
              # exist here. Before the first record, so nothing is dropped.
              Snails.logger.after_fork
              run_connection(sfd)
              Sock.sphttp_exit(0)
            end
            i += 1
          end
          # Reap children until none remain, then emit the single aggregated
          # run_end (Tep::Events.run_end_aggregated) from the parent.
          loop do
            gone = Sock.sphttp_wait_any
            if gone < 0
              break
            end
          end
          if Sock.sphttp_shutdown_requested != 0
            Tep.on_shutdown
          end
        else
          run_connection(sfd)
          # Single process: this one is the parent, so emit run_end here.
          if Sock.sphttp_shutdown_requested != 0
            Tep.on_shutdown
          end
          # Exit outright, as the threaded server does: the app's job-loop green
          # thread is parked on its queue, and spinel runs every remaining green
          # thread to completion when main returns.
          Sock.sphttp_exit(0)
        end
      end

      # Spawn the accept fiber and pump the scheduler. Called inside each
      # prefork child. Loops on `tick` rather than `run_until_empty` because the
      # accept fiber parks on io_wait indefinitely: run_until_empty bails when
      # no fiber is ready on this pass, but the parked accept must keep being
      # polled to wake when a connection arrives.
      def run_connection(sfd)
        # The job loop runs once per server process -- the same contract as the
        # threaded server's run_connection. The process record shares this
        # point, so it names the same per-process values.
        Tep.log_process_started(@port, @workers)
        ActiveJob::Launcher.start
        f = Fiber.new { accept_loop(sfd) }
        Tep::Scheduler.spawn_fiber(f)
        while Tep::Scheduler.alive_count > 0
          # Shutdown is the connection loop's exit condition, not the fibers'. The accept
          # fiber honours the term flag and dies, but a perpetual fiber an app
          # registered (a job-queue drain running `loop { pause; drain }`) keeps
          # alive_count > 0 forever, so waiting on the fibers alone would leave
          # the process squatting on the port, accepting into the backlog and
          # serving none of it. Ctrl-C must mean exit.
          if Sock.sphttp_shutdown_requested != 0
            break
          end
          Tep::Scheduler.tick(1000)
        end
      end

      # Accept loop. Each accepted connection becomes its own fiber, closing
      # over the just-accepted `client` fd.
      def accept_loop(sfd)
        while true
          # Check the term flag before parking so a shutdown request is not
          # slept past; the 1s io_wait timeout below bounds that latency. The
          # parent (or this process, for workers=1) emits the aggregated run_end
          # after all workers exit.
          if Sock.sphttp_shutdown_requested != 0
            break
          end
          # Bounded wait, so the flag above is re-read once per second even when
          # traffic is idle.
          ready = Tep::Scheduler.io_wait(sfd, Tep::Scheduler::READ, 1)
          if ready == 0
            next
          end
          client = Sock.sphttp_accept_nb(sfd)
          if client < 0
            next
          end
          Sock.sphttp_set_nonblock(client)
          conn = Fiber.new { handle_connection(client) }
          Tep::Scheduler.spawn_fiber(conn)
        end
      end

      # Per-connection lifecycle. Per-request work lives in handle_one so each
      # keep-alive iteration gets its own GC scope: inline in this loop, the
      # per-request roots (blob, req, res, everything dispatch allocates) would
      # hoist to this long-lived scope and pile up across the connection's
      # requests, defeating the young-gen GC.
      def handle_connection(client)
        keep_going = true
        while keep_going
          keep_going = handle_one(client)
        end
        Sock.sphttp_close(client)
      end

      # Process exactly one request on `client`. Returns true to keep the
      # connection open for the next keep-alive request, false to close.
      def handle_one(client)
        blob = read_request_blob(client, KEEPALIVE_TIMEOUT)
        if blob.length == 0
          return false
        end
        req = Parser.parse(blob)
        if req == nil
          send_simple(client, 400, "bad request")
          return false
        end

        body_outcome = req.consume_body_via_scheduler(client)
        if body_outcome != :ok
          send_simple(client, Tep.body_error_status(body_outcome),
                      Tep.body_error_message(body_outcome))
          return false
        end

        res = Response.new
        begin
          Tep::APP.dispatch(req, res)
        rescue Exception => failure
          raise if Snails::ErrorBoundary.fatal?(failure)
          # One request's failure is not the worker's. A fiber that unwinds
          # here would take the whole scheduler loop with it, killing every
          # other open connection. The request path already wrote the
          # `request.failed` record.
          send_simple(client, 500, "internal server error")
          return false
        end

        # Streaming responses use chunked Connection: close, so end the
        # keep-alive loop after this response -- else the next iteration would
        # read the same fd after the stream's terminator.
        keep_alive = req.keep_alive? && !res.halted_close? && !res.streaming
        write_response(client, req, res, keep_alive)
        keep_alive
      end

      # Non-blocking request reader: returns the accumulated blob once
      # "\r\n\r\n" is seen, or "" on timeout / EOF / oversize.
      def read_request_blob(fd, timeout_seconds)
        buf = +""
        deadline = Time.now.to_i + timeout_seconds
        while buf.length < MAX_REQUEST_BYTES
          remaining = deadline - Time.now.to_i
          if remaining <= 0
            return ""
          end
          ready = Tep::Scheduler.io_wait(fd, Tep::Scheduler::READ, remaining)
          if ready == 0
            return ""
          end
          chunk = Sock.sphttp_recv_some(fd, 4096)
          if chunk.length == 0
            return ""
          end
          buf << chunk
          if buf.length >= 4 && buf.include?("\r\n\r\n")
            return buf
          end
        end
        ""
      end

      # The response head and body for one request: status line, headers,
      # cookies, connection framing, then either the body bytes or a chunked
      # stream. WebSocket upgrades are refused (see the branch below). Private
      # on purpose: the fiber blocks in accept_loop capture this instance.
      def write_response(client, req, res, keep_alive)
        # WebSocket upgrade branch, entered via res.start_websocket in the
        # handler after Handshake.check passes. Writes the 101 head, assigns the
        # client fd to the driver, runs the recv loop (which returns on peer
        # EOF, idle timeout or a CLOSE round-trip), and leaves the fd for
        # handle_connection to close.
        if res.upgrading_ws
          # This server serves the HTTP path only: the driver's recv loop wants
          # a parked green thread (Tep::Server::Threaded), and on the main
          # thread it would hold every other connection. Refuse rather than
          # serve it wrong.
          send_simple(client, 501,
            "websocket upgrade needs the default server")
          return 0
        end

        # Streaming branch -- chunked, Connection: close. Writes the head
        # immediately, hands a Tep::Stream writer to the handler's
        # Streamer#pump, then emits the terminator. pump runs cooperatively: it
        # parks in `io_wait` between writes (a proxy streamer waits on its
        # upstream fd), so other fibers keep running while the stream is in
        # flight.
        if res.streaming
          res.headers["Transfer-Encoding"] = "chunked"
          if !res.headers.key?("Content-Type")
            res.headers["Content-Type"] = "text/event-stream"
          end
          reason = Tep.reason(res.status)
          head = req.http_version + " " + res.status.to_s + " " + reason + "\r\n"
          res.headers.each do |k, v|
            head << k + ": " + v + "\r\n"
          end
          res.set_cookies.each do |line|
            head << "Set-Cookie: " + line + "\r\n"
          end
          head << "Connection: close\r\n\r\n"
          Sock.sphttp_write_str(client, head)
          out = Tep::Stream.new(client)
          res.streamer.pump(out)
          Sock.sphttp_write_chunk_end(client)
          return 0
        end

        # Default Content-Type for inline-body responses: without it the
        # Security::Headers nosniff default leaves the browser refusing to
        # interpret the body as HTML.
        if res.file_path.length == 0 && res.body.length > 0 && !res.headers.key?("Content-Type")
          res.headers["Content-Type"] = "text/html; charset=utf-8"
        end
        reason = Tep.reason(res.status)
        head = req.http_version + " " + res.status.to_s + " " + reason + "\r\n"
        res.headers.each do |k, v|
          head << k + ": " + v + "\r\n"
        end
        res.set_cookies.each do |line|
          head << "Set-Cookie: " + line + "\r\n"
        end
        if keep_alive
          head << "Connection: keep-alive\r\n"
        else
          head << "Connection: close\r\n"
        end
        if res.file_path.length > 0
          fs = Sock.sphttp_filesize(res.file_path)
          head << "Content-Length: " + fs.to_s + "\r\n\r\n"
          Sock.sphttp_write_str(client, head)
          Sock.sphttp_sendfile(client, res.file_path) unless res.headers_only
        else
          # Bytes, both times: `length` counts characters, and `write_str`
          # crosses the FFI as a NUL-terminated C string -- a binary body would
          # be cut at its first 0x00 while Content-Length announced the full
          # size, leaving the client waiting out a mismatch.
          head << "Content-Length: " + res.body.bytesize.to_s + "\r\n\r\n"
          Sock.sphttp_write_str(client, head)
          if res.body.bytesize > 0 && !res.headers_only
            Sock.sphttp_write_bytes(client, res.body, res.body.bytesize)
          end
        end
      end

      def send_simple(client, status, msg)
        reason = Tep.reason(status)
        head = "HTTP/1.0 " + status.to_s + " " + reason + "\r\n" +
               "Content-Length: " + msg.length.to_s + "\r\n" +
               "Connection: close\r\n\r\n" + msg
        Sock.sphttp_write_str(client, head)
      end

      # Private on purpose: `run` is the entry; the connection loop and
      # per-connection helpers may change without notice.
      private :run_connection, :accept_loop, :handle_connection, :handle_one
      private :read_request_blob, :write_response, :send_simple
    end
  end
end
