# Tep::WebSocket::Driver -- per-connection state, outbound writers, and
# the handler slots the recv loop dispatches into.
#
# Built after the handshake completes and before the recv loop starts.
# Event handlers are objects installed with `set_on_*`, not blocks.
module Tep
  module WebSocket
    class Driver
      attr_accessor :fd, :max_frame_size, :subprotocol
      # One slot per wire event; each starts as a no-op base handler so a
      # dispatch never has to nil-check its slot.
      attr_accessor :h_open, :h_message, :h_close, :h_ping, :h_pong, :h_error

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

      def set_max_frame_size(n)
        @max_frame_size = n
      end

      # Assign the live client fd: the driver is built before that fd is
      # visible, so the upgrade path sets it here just before the recv loop
      # starts.
      def set_fd(new_fd)
        @fd = new_fd
      end

      def set_subprotocol(name)
        @subprotocol = name
      end

      def set_on_open(h);    @h_open = h;    end
      def set_on_message(h); @h_message = h; end
      def set_on_close(h);   @h_close = h;   end
      def set_on_ping(h);    @h_ping = h;    end
      def set_on_pong(h);    @h_pong = h;    end
      def set_on_error(h);   @h_error = h;   end

      # `text` deliberately has no `write(s)` alias: an uncalled
      # String-param method reads its parameter as int under spinel and
      # fails the C compile.
      def text(s)
        write_frame(Tep::WebSocket::OPCODE_TEXT, s)
      end

      def binary(bytes)
        write_frame(Tep::WebSocket::OPCODE_BINARY, bytes)
      end

      # `ping(payload)` -- send a ping frame.
      #
      # @param payload [String] must fit a control frame: 125 bytes or fewer --
      #   the size is not checked here
      # @return [Integer] the write's result, or -1 once `retire` has run
      def ping(payload)
        write_frame(Tep::WebSocket::OPCODE_PING, payload)
      end

      # `pong(payload)` -- send a pong frame.
      #
      # @param payload [String] the ping's payload carried back, as §5.5.3
      #   requires; 125 bytes or fewer
      # @return [Integer] the write's result, or -1 once `retire` has run
      def pong(payload)
        write_frame(Tep::WebSocket::OPCODE_PONG, payload)
      end

      # `close(code, reason)` -- send a close frame.
      #
      # @param code [Integer] the close code to report
      # @param reason [String] truncated to 123 bytes so that code plus reason
      #   fit a control frame's 125-byte payload
      # @return [Integer] the write's result, or -1 once `retire` has run
      def close(code, reason)
        body = encode_close_payload(code, reason)
        write_frame(Tep::WebSocket::OPCODE_CLOSE, body)
      end

      # `write_frame(opcode, payload)` -- the one path every outbound frame
      # takes.
      #
      # The lock keeps concurrent writers from interleaving bytes on the wire,
      # and `retire` flips the closed flag under the same lock so no write can
      # START once the fd's owner has decided to close it. That ordering is
      # what makes an fd NUMBER safe to hold across threads: the kernel hands a
      # closed fd's number to the next accept, and a late write would land in a
      # stranger's socket.
      #
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

      # `retire` -- the fd's owner calls this before closing the fd: a write
      # already in flight finishes, and every later one is refused.
      #
      # That refusal is also how a ping thread learns to exit.
      #
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
    class Event
      attr_accessor :data, :code, :reason

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
    class Handler
      attr_accessor :req

      def initialize
        @req = Tep::Request.new
      end

      def handle_event(event)
      end
    end
  end
end
