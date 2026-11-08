# Tep::WebSocket::Connection -- per-connection recv loop.
#
# Runs on the connection's own green thread once the 101 response has
# been written: parks on the IO wrapper until bytes arrive, then
# dispatches every complete frame the accumulator holds. The accumulator
# is this connection's own String, so no shared buffer exists.
module Tep
  module WebSocket
    class Connection
      attr_accessor :driver, :fd, :idle_timeout_seconds

      # bind the connection to its driver and to the IO wrapper the recv loop
      # parks on.
      #
      # @param driver [Driver] the driver built at handshake time; the
      #   connection reads `fd` from it
      # @param io [IO] the `IO.for_fd` wrapper around that same fd -- a raw fd
      #   has no `wait_readable`, and the server owns the wrapper and closes it
      # @return [void]
      def initialize(driver, io)
        @driver = driver
        @fd     = driver.fd
        @io     = io
        @idle_timeout_seconds = 300
      end

      def set_idle_timeout(seconds)
        @idle_timeout_seconds = seconds
      end

      # drive the recv loop until the connection ends.
      #
      # The caller owns the fd lifecycle -- `run` never closes it. Every
      # exit passes through `dispatch_close`, so the broadcast registry
      # drops this fd's subscriptions while the number still belongs to
      # this connection.
      #
      # @return [void]
      def run
        # Synthetic open event before the first recv, so a handler can
        # greet the client.
        dispatch_open(@driver)

        # Inbound byte accumulator, drained a frame at a time; a partial
        # tail is carried forward via byteslice.
        inbuf = +""
        while true
          ready = @io.wait_readable(@idle_timeout_seconds)
          if ready.nil?
            @driver.close(Tep::WebSocket::CLOSE_GOING_AWAY, "idle timeout")
            dispatch_close(@driver, Tep::WebSocket::CLOSE_GOING_AWAY, "idle timeout")
            return
          end

          chunk = Sock.sp_net_recv_some(@fd, 65536)
          if chunk.bytesize == 0
            # EOF: dispatch close without sending one back.
            dispatch_close(@driver, Tep::WebSocket::CLOSE_GOING_AWAY, "")
            return
          end
          inbuf = inbuf + chunk

          while true
            # bytesize, not length: inbuf is masked binary, so a char count
            # under-reports avail (a complete frame reads as "need") and
            # truncates the carried tail whenever XOR'd bytes form
            # multi-byte sequences.
            r = Tep::WebSocket::Frame.parse_from_buf(inbuf, 0, inbuf.bytesize)
            if r.outcome == "need"
              break
            end
            if r.outcome == "close"
              @driver.close(r.close_code, "protocol error")
              dispatch_close(@driver, r.close_code, "protocol error")
              return
            end
            dispatch_frame(@driver, r.frame)
            if r.consumed >= inbuf.bytesize
              inbuf = +""
              break
            end
            inbuf = inbuf.byteslice(r.consumed, inbuf.bytesize - r.consumed)
          end
        end
      end

      def dispatch_frame(driver, frame)
        op = frame.opcode
        if op == Tep::WebSocket::OPCODE_TEXT
          dispatch_message(driver, frame.payload, true)
        elsif op == Tep::WebSocket::OPCODE_BINARY
          dispatch_message(driver, frame.payload, false)
        elsif op == Tep::WebSocket::OPCODE_PING
          # Auto-pong with the ping's payload (§5.5.3).
          driver.pong(frame.payload)
          dispatch_ping(driver, frame.payload)
        elsif op == Tep::WebSocket::OPCODE_PONG
          dispatch_pong(driver, frame.payload)
        elsif op == Tep::WebSocket::OPCODE_CLOSE
          code = 0
          reason = +""
          # bytesize/getbyte/byteslice: the close payload is binary (2-byte
          # code + UTF-8 reason), and char indexing misreads the code when
          # the reason opens with a multi-byte character.
          if frame.payload.bytesize >= 2
            code = (frame.payload.getbyte(0) << 8) | frame.payload.getbyte(1)
            if frame.payload.bytesize > 2
              reason = frame.payload.byteslice(2, frame.payload.bytesize - 2)
            end
          end
          driver.close(code == 0 ? Tep::WebSocket::CLOSE_NORMAL : code, reason)
          dispatch_close(driver, code, reason)
        end
      end

      def dispatch_open(driver)
        evt = Tep::WebSocket::Event.new
        driver.h_open.handle_event(evt)
      end

      def dispatch_message(driver, data, text)
        evt = Tep::WebSocket::Event.new
        evt.data = data
        driver.h_message.handle_event(evt)
      end

      def dispatch_ping(driver, data)
        evt = Tep::WebSocket::Event.new
        evt.data = data
        driver.h_ping.handle_event(evt)
      end

      def dispatch_pong(driver, data)
        evt = Tep::WebSocket::Event.new
        evt.data = data
        driver.h_pong.handle_event(evt)
      end

      def dispatch_close(driver, code, reason)
        evt = Tep::WebSocket::Event.new
        evt.code = code
        evt.reason = reason
        driver.h_close.handle_event(evt)
        # Drop every broadcast subscription and presence row keyed on this
        # fd. Both calls are idempotent, so an app that unsubscribes
        # explicitly as well just finds zero matches.
        Tep::Broadcast.unsubscribe_fd(driver.fd)
        Tep::Presence.untrack_by_fd(driver.fd)
      end

      # Private on purpose: `run` is the entry; the dispatch helpers may
      # change without notice.
      private :dispatch_frame, :dispatch_open, :dispatch_message
      private :dispatch_ping, :dispatch_pong, :dispatch_close
    end
  end
end
