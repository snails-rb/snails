# Tep::WebSocket::Frame -- single-frame codec (parse and emit).
#
# Server-side: emit never masks (§5.3), and parse treats unmasked
# client frames, reserved bits or opcodes, and oversized or fragmented
# control frames as protocol violations.
module Tep
  module WebSocket
    class Frame
      attr_accessor :fin, :opcode, :payload

      def initialize(fin, opcode, payload)
        @fin     = fin
        @opcode  = opcode
        @payload = payload
      end

      # the unmasked server-side wire bytes for this frame, using the shortest
      # length form that fits.
      #
      # The header is assembled as byte values and emitted with `pack("C*")`
      # because the 16-bit length form has a `0x00` high byte for any
      # 126..255-byte payload: the header must be binary-safe, and
      # `+ @payload` concatenates NUL-safely.
      #
      # @return [String] the framed bytes, ready to write
      def encode_unmasked
        head = []
        b0 = (@fin ? 0x80 : 0x00) | (@opcode & 0x0f)
        head << b0

        # bytesize, not length: the wire header advertises BYTES, and a
        # char count under-reports any multi-byte payload, desyncing the
        # peer's parser.
        plen = @payload.bytesize
        if plen <= 125
          head << plen
        elsif plen <= 65535
          head << 126
          head << ((plen >> 8) & 0xff)
          head << (plen & 0xff)
        else
          head << 127
          i = 7
          while i >= 0
            head << ((plen >> (i * 8)) & 0xff)
            i -= 1
          end
        end
        head.pack("C*") + @payload
      end

      def self.byte_to_chr(n)
        (n & 0xff).chr
      end

      # parse one frame out of the bytes received so far. Byte reads use
      # `String#getbyte`, which sees the 0x00 high byte of the 16-bit length
      # form regardless of the payload's content.
      #
      # @param s [String] binary String of received bytes
      # @param start [Integer] the byte offset to begin at
      # @param avail [Integer] the count of valid bytes
      # @return [ParseResult] one of three outcomes:
      #   "ok" -> `.frame` populated, `.consumed` bytes used
      #   "need" -> need more bytes (consumed == 0)
      #   "close" -> protocol violation; close with `.close_code`
      def self.parse_from_buf(s, start, avail)
        out = Tep::WebSocket::ParseResult.new
        if avail - start < 2
          out.outcome = "need"
          return out
        end

        b0 = s.getbyte(start)
        b1 = s.getbyte(start + 1)
        fin    = (b0 & 0x80) != 0
        rsv    = b0 & 0x70
        opcode = b0 & 0x0f
        masked = (b1 & 0x80) != 0
        len7   = b1 & 0x7f

        if rsv != 0
          out.outcome = "close"
          out.close_code = Tep::WebSocket::CLOSE_PROTOCOL_ERROR
          return out
        end
        if reserved_opcode?(opcode)
          out.outcome = "close"
          out.close_code = Tep::WebSocket::CLOSE_PROTOCOL_ERROR
          return out
        end
        if control_opcode?(opcode)
          if !fin
            out.outcome = "close"
            out.close_code = Tep::WebSocket::CLOSE_PROTOCOL_ERROR
            return out
          end
          if len7 > 125
            out.outcome = "close"
            out.close_code = Tep::WebSocket::CLOSE_PROTOCOL_ERROR
            return out
          end
        end
        if !masked
          out.outcome = "close"
          out.close_code = Tep::WebSocket::CLOSE_PROTOCOL_ERROR
          return out
        end

        pos = start + 2
        plen = 0
        if len7 < 126
          plen = len7
        elsif len7 == 126
          if avail - pos < 2
            out.outcome = "need"
            return out
          end
          h = s.getbyte(pos)
          l = s.getbyte(pos + 1)
          plen = (h << 8) | l
          pos += 2
        else
          if avail - pos < 8
            out.outcome = "need"
            return out
          end
          plen = 0
          i = 0
          while i < 8
            plen = (plen << 8) | s.getbyte(pos + i)
            i += 1
          end
          pos += 8
        end

        if avail - pos < 4
          out.outcome = "need"
          return out
        end
        m0 = s.getbyte(pos)
        m1 = s.getbyte(pos + 1)
        m2 = s.getbyte(pos + 2)
        m3 = s.getbyte(pos + 3)
        pos += 4

        if avail - pos < plen
          out.outcome = "need"
          return out
        end

        # Unmask into a byte array and pack: the recovered payload is
        # arbitrary bytes, so the string must stay binary-safe.
        bytes = []
        i = 0
        while i < plen
          b = s.getbyte(pos + i)
          mask_byte = 0
          if (i & 3) == 0
            mask_byte = m0
          elsif (i & 3) == 1
            mask_byte = m1
          elsif (i & 3) == 2
            mask_byte = m2
          else
            mask_byte = m3
          end
          bytes << (b ^ mask_byte)
          i += 1
        end
        payload = bytes.pack("C*")

        out.outcome   = "ok"
        out.frame    = Tep::WebSocket::Frame.new(fin, opcode, payload)
        out.consumed = pos + plen - start
        out
      end

      def self.reserved_opcode?(op)
        if op == Tep::WebSocket::OPCODE_CONTINUATION
          return false
        end
        if op == Tep::WebSocket::OPCODE_TEXT
          return false
        end
        if op == Tep::WebSocket::OPCODE_BINARY
          return false
        end
        if op == Tep::WebSocket::OPCODE_CLOSE
          return false
        end
        if op == Tep::WebSocket::OPCODE_PING
          return false
        end
        if op == Tep::WebSocket::OPCODE_PONG
          return false
        end
        true
      end

      def self.control_opcode?(op)
        op == Tep::WebSocket::OPCODE_CLOSE ||
          op == Tep::WebSocket::OPCODE_PING ||
          op == Tep::WebSocket::OPCODE_PONG
      end

      # Private on purpose: `parse_from_buf` is the entry; the opcode
      # classifiers are free to change without notice.
      private_class_method :reserved_opcode?, :control_opcode?
    end

    # Carries one of three outcomes: a parsed frame, a "need more bytes"
    # signal, or a close code for a protocol violation. The field is
    # `outcome`, not `status`: a `status` attr slot collides with
    # Tep::Response#status (Integer) in spinel's same-name attr
    # unification, widening Tep.reason to poly and breaking the build.
    class ParseResult
      attr_accessor :outcome, :frame, :consumed, :close_code

      def initialize
        @outcome    = +""
        @frame      = Tep::WebSocket::Frame.new(true, 0, "")
        @consumed   = 0
        @close_code = 0
      end
    end
  end
end
