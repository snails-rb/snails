# Tep::Server::Threaded -- one green thread per connection. recv/write park on
# EAGAIN and free the OS worker, so a held WebSocket costs one small stack and a
# slow subscriber stalls only its own writer.
#
# Client fds stay non-blocking (sp_net parks only on EAGAIN); each connection
# owns an `IO.for_fd` wrapper for timed waits, since a raw fd has no
# `wait_readable`.
module Tep
  class Server
    class Threaded
      # Cap on one request's start-line + headers, in bytes (64 KiB).
      MAX_REQUEST_BYTES = 65535

      # Idle keep-alive timeout between requests on one connection, in seconds.
      KEEPALIVE_TIMEOUT = 30

      # listen and serve, one green thread per connection. A port already in use
      # stops the process with exit(1); `workers` above one preforks that many
      # servers of the same shape; `quiet` only suppresses the banner.
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
          $stderr.puts Tep.display_name + ": cannot bind to port " +
                       port.to_s + " (already in use?)"
          exit(1)
        end
        if !quiet
          puts Tep.display_name + " (" + RUBY_ENGINE +
               ") listening on http://0.0.0.0:" + port.to_s +
               ", pid " + Sock.sphttp_getpid.to_s
          puts "  one green thread per connection; OS workers: " +
               Tep.os_workers_desc + "; processes: " +
               Tep.processes_desc(workers)
          $stdout.flush
        end

        # Install SIGTERM/SIGINT handlers before fork so children inherit them;
        # the accept loop checks the term flag after every accept.
        Sock.sphttp_install_term_handlers

        # `-w N` still preforks: each child is a threaded server of its own.
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
              Sock.sphttp_exit(0)   # see the single-process exit below
            end
            i += 1
          end
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
          if Sock.sphttp_shutdown_requested != 0
            Tep.on_shutdown
          end
          # Exit outright: spinel runs every remaining green thread to
          # completion when main returns, and the connection threads are parked
          # on sockets that may never speak again (a keep-alive waits 30s, an
          # idle WebSocket 300s). A server asked to stop stops.
          Sock.sphttp_exit(0)
        end
      end

      # The accept loop, on the calling thread. A timed wait on the listen
      # socket, one second at a time, so SIGTERM/SIGINT is noticed within a
      # second when no connection arrives: the handler only sets a flag, and a
      # thread parked in a plain `accept` is never woken to read it. The accept
      # itself is non-blocking, and -1 means a spurious wake -- retry.
      def run_connection(sfd)
        # The job loop runs once per server process -- here, after any prefork:
        # a thread started before the fork would not exist in the child, whose
        # queued jobs would then never drain. The process record shares this
        # point, so it names the same per-process values.
        Tep.log_process_started(@port, @workers)
        ActiveJob::Launcher.start
        Sock.sphttp_set_nonblock(sfd)
        lio = IO.for_fd(sfd, autoclose: false)
        while true
          if Sock.sphttp_shutdown_requested != 0
            break
          end
          ready = lio.wait_readable(1)
          if ready.nil?
            next
          end
          client = Sock.sphttp_accept_nb(sfd)
          if client < 0
            next
          end
          Sock.sphttp_set_nonblock(client)
          Thread.new(client) do |c|
            handle_connection(c)
          end
        end
        lio.close
      end

      # Per-connection lifecycle: one wrapper for the timed waits, the
      # keep-alive loop, then both the wrapper's dup and the fd close.
      # Per-request work lives in handle_one so each iteration gets its own GC
      # scope: inline in this loop, the per-request roots (blob, req, res,
      # everything dispatch allocates) would hoist to the connection's scope
      # and pile up across its requests, defeating the young-gen GC.
      def handle_connection(client)
        io = IO.for_fd(client, autoclose: false)
        keep_going = true
        while keep_going
          keep_going = handle_one(client, io)
        end
        io.close
        Sock.sphttp_close(client)
      end

      # Process exactly one request on `client`. Returns true to keep the
      # connection open for the next keep-alive request, false to close.
      def handle_one(client, io)
        blob = read_request_blob(client, io, KEEPALIVE_TIMEOUT)
        if blob.length == 0
          return false
        end
        req = Parser.parse(blob)
        if req == nil
          send_simple(client, 400, "bad request")
          return false
        end

        body_outcome = req.consume_body_via_io(io, client)
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
          # One request's failure is not the connection's, and certainly not the
          # process's: a thread that unwound here would take only itself down,
          # but the client still deserves the 500. The request path already
          # wrote the `request.failed` record.
          send_simple(client, 500, "internal server error")
          return false
        end

        # Streaming responses use chunked Connection: close (as the blocking
        # server does).
        keep_alive = req.keep_alive? && !res.halted_close? && !res.streaming
        write_response(client, io, req, res, keep_alive)
        keep_alive
      end

      # Request reader: returns the accumulated blob once "\r\n\r\n" is seen, or
      # "" on timeout / EOF / oversize. The timed wait parks the thread; a peer
      # that closes wakes it (EOF reads as zero bytes).
      def read_request_blob(fd, io, timeout_seconds)
        buf = +""
        deadline = Time.now.to_i + timeout_seconds
        while buf.length < MAX_REQUEST_BYTES
          remaining = deadline - Time.now.to_i
          if remaining <= 0
            return ""
          end
          ready = io.wait_readable(remaining)
          if ready.nil?
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
      # stream. WebSocket upgrades leave through their own branch first.
      def write_response(client, io, req, res, keep_alive)
        # WebSocket upgrade branch, entered via res.start_websocket in the
        # handler after Handshake.check passes. Writes the 101 head, then hands
        # the fd and this connection's wait wrapper to the driver and runs the
        # recv loop, which returns when the connection closes.
        if res.upgrading_ws
          head = Tep::WebSocket::Handshake.build_response(
            res.ws_accept_key, res.ws_driver.subprotocol)
          Sock.sphttp_write_str(client, head)
          res.ws_driver.set_fd(client)
          conn = Tep::WebSocket::Connection.new(res.ws_driver, io)
          conn.run
          # The recv loop is done with the socket. Retire the driver before the
          # caller closes the fd: an fd number is not a connection, and the
          # kernel may hand this one to the next accept while a ping thread or a
          # broadcast still holds it. See Tep::WebSocket::Driver#write_frame.
          res.ws_driver.retire
          return 0
        end

        # Streaming branch -- chunked, Connection: close.
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

        # Default Content-Type for inline-body responses.
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
          # crosses the FFI as a NUL-terminated C string.
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
      private :run_connection, :handle_connection, :handle_one
      private :read_request_blob, :write_response, :send_simple
    end
  end
end
