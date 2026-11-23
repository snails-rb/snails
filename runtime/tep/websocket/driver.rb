# Tep::WebSocket::Driver -- per-connection state, outbound writers, and
# the handlers the recv loop dispatches into.
#
# Internal implementation, not app API.
#
# Built after the handshake completes and before the recv loop starts.
# Event handlers are objects installed with `set_on_*`, not blocks.
#
# @api internal
module Tep
  module WebSocket
    class Driver
      # Not app API: the connection loop and the upgrade path read these.
      #
      # @api internal
      attr_accessor :fd, :max_frame_size, :subprotocol
      # One handler per wire event; each starts as a no-op base handler so a
      # dispatch never has to nil-check its handler.
      #
      # Not app API: internal event sinks installed with `set_on_*`.
      #
      # @api internal
      attr_accessor :h_open, :h_message, :h_close, :h_ping, :h_pong, :h_error

      # Not app API: built by the upgrade path and by the Broadcast type seed.
      #
      # @api internal
      def initialize(fd)
        @fd             = fd
        @closed         = false
        @wlock          = Mutex.new
        @max_frame_size = Tep::WebSocket::DEFAULT_MAX_FRAME
        @subprotocol    = +""
        @h_open    = Tep::WebSocket::Handler.new
        @h_message = Tep::WebSocket::Handler.new
        @h_close   = Tep::WebSocket::Handler.new
        @h_ping    = Tep::WebSocket::Handler.new
        @h_pong    = Tep::WebSocket::Handler.new
        @h_error   = Tep::WebSocket::Handler.new
      end

      # Not app API: no supported tuning surface; the default cap applies.
      #
      # @api internal
      def set_max_frame_size(n)
        @max_frame_size = n
      end

      # Assign the live client fd: the driver is built before that fd is
      # visible, so the upgrade path sets it here just before the recv loop
      # starts.
      #
      # Not app API: the server's upgrade path assigns it.
      #
      # @api internal
      def set_fd(new_fd)
        @fd = new_fd
      end

      # Not app API: the upgrade path echoes the negotiated protocol.
      #
      # @api internal
      def set_subprotocol(name)
        @subprotocol = name
      end

      # Not app API: internal event sinks the connection loop dispatches into.
      #
      # @api internal
      def set_on_open(h);    @h_open = h;    end
      # @api internal
      def set_on_message(h); @h_message = h; end
      # @api internal
      def set_on_close(h);   @h_close = h;   end
      # @api internal
      def set_on_ping(h);    @h_ping = h;    end
      # @api internal
      def set_on_pong(h);    @h_pong = h;    end
      # @api internal
      def set_on_error(h);   @h_error = h;   end

      # `text` deliberately has no `write(s)` alias: an uncalled
      # String-param method reads its parameter as int under spinel and
      # fails the C compile.
      #
      # Not app API: outbound writers belong to the internal stack.
      #
      # @api internal
      def text(s)
        write_frame(Tep::WebSocket::OPCODE_TEXT, s)
      end

      # Not app API: outbound writers belong to the internal stack.
      #
      # @api internal
      def binary(bytes)
        write_frame(Tep::WebSocket::OPCODE_BINARY, bytes)
      end

      # send a ping frame.
      #
      # Not app API: outbound writers belong to the internal stack.
      #
      # @api internal
      # @param payload [String] must fit a control frame: 125 bytes or fewer --
      #   the size is not checked here
      # @return [Integer] the write's result, or -1 once `retire` has run
      def ping(payload)
        write_frame(Tep::WebSocket::OPCODE_PING, payload)
      end

      # send a pong frame.
      #
      # Not app API: outbound writers belong to the internal stack.
      #
      # @api internal
      # @param payload [String] the ping's payload carried back, as §5.5.3
      #   requires; 125 bytes or fewer
      # @return [Integer] the write's result, or -1 once `retire` has run
      def pong(payload)
        write_frame(Tep::WebSocket::OPCODE_PONG, payload)
      end

      # send a close frame.
      #
      # Not app API: outbound writers belong to the internal stack.
      #
      # @api internal
      # @param code [Integer] the close code to report
      # @param reason [String] truncated to 123 bytes so that code plus reason
      #   fit a control frame's 125-byte payload
      # @return [Integer] the write's result, or -1 once `retire` has run
      def close(code, reason)
        body = encode_close_payload(code, reason)
        write_frame(Tep::WebSocket::OPCODE_CLOSE, body)
      end

      # the one path every outbound frame takes.
      #
      # The lock keeps concurrent writers from interleaving bytes on the wire,
      # and `retire` flips the closed flag under the same lock so no write can
      # START once the fd's owner has decided to close it. That ordering is
      # what makes an fd NUMBER safe to hold across threads: the kernel hands a
      # closed fd's number to the next accept, and a late write would land in a
      # stranger's socket.
      #
      # Not app API: `text`, `binary`, `ping`, `pong`, and `close` are the
      # internal callers.
      #
      # @api internal
      # @param opcode [Integer] the frame opcode
      # @param payload [String] the frame payload
      # @return [Integer] the write's result, or -1 once retired
      def write_frame(opcode, payload)
        r = -1
        @wlock.synchronize do
          if !@closed
            r = send_frame(@fd, opcode, payload)
          end
        end
        r
      end

      # the fd's owner calls this before closing the fd: a write already in
      # flight finishes, and every later one is refused.
      #
      # That refusal is also how a ping thread learns to exit.
      #
      # Not app API: the server retires the driver when the recv loop ends.
      #
      # @api internal
      # @return [void]
      def retire
        @wlock.synchronize do
          @closed = true
        end
      end

      # Encode the frame unmasked and write the full byte count. Nothing
      # else reaches the raw fd.
      def send_frame(fd, opcode, payload)
        frame = Tep::WebSocket::Frame.new(true, opcode, payload)
        bytes = frame.encode_unmasked
        Sock.sphttp_write_bytes(fd, bytes, bytes.bytesize)
      end

      # 2-byte big-endian code + UTF-8 reason. An empty payload is legal
      # (§5.5.1), and `code == 0` emits exactly that.
      def encode_close_payload(code, reason)
        if code == 0
          return ""
        end
        out = Tep::WebSocket::Frame.byte_to_chr((code >> 8) & 0xff) +
              Tep::WebSocket::Frame.byte_to_chr(code & 0xff)
        if reason.bytesize > 123
          out + reason.byteslice(0, 123)
        else
          out + reason
        end
      end

      # Private on purpose: `text`, `binary`, `ping`, `pong`, and `close` are
      # the entries; the frame writer and encoder may change without notice.
      private :send_frame, :encode_close_payload
    end

    # One Event per dispatched wire event. `code`/`reason` are set only
    # for close; there is no text/binary flag, so a handler receives the
    # payload as data either way.
    #
    # @api internal
    class Event
      # Not app API: the connection loop fills these fields.
      #
      # @api internal
      attr_accessor :data, :code, :reason

      # Not app API: the internal dispatch builds one per wire event.
      #
      # @api internal
      def initialize
        @data   = +""
        @code   = 0
        @reason = +""
      end
    end

    # Base class for event handlers: subclass and override
    # `handle_event(event)`; the driver holds one instance per event type.
    #
    # `req` is the request that opened the connection, set at upgrade
    # time and shared by every event on it -- there is no per-frame
    # request.
    #
    # @api internal
    class Handler
      # Not app API: the upgrade path assigns the request.
      #
      # @api internal
      attr_accessor :req

      # Not app API: the internal dispatch builds one per connection.
      #
      # @api internal
      def initialize
        @req = Tep::Request.new
      end

      # Not app API: the connection loop calls it; apps do not.
      #
      # @api internal
      def handle_event(event)
      end
    end
  end
end
