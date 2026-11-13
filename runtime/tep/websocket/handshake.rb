# Tep::WebSocket::Handshake -- RFC 6455 §1.3 server-side handshake. `check(req)`
# validates the upgrade and returns the accept key and offered subprotocols;
# `build_response` returns the raw HTTP/1.1 101 bytes.
#
# A rejection sets `valid = false` and fills `reason`; it never raises.
module Tep
  module WebSocket
    class Handshake
      # whether this request may upgrade to a WebSocket. The verdict arrives as
      # a value: a rejection fills `reason` instead of raising, so the caller
      # answers it.
      #
      # @param req [Tep::Request] the request under test
      # @return [Result] `valid`, plus `reason` on a rejection or
      #   `accept_key` and `protocols` on success
      def self.check(req)
        out = Tep::WebSocket::Handshake::Result.new

        if req.verb != "GET"
          out.valid = false
          out.reason = "bad verb"
          return out
        end

        # Header names arrive downcased from Tep::Request while values keep
        # their case, so values are matched case-insensitively.
        upgrade = req.req_headers["upgrade"]
        if icontains(upgrade, "websocket") == false
          out.valid = false
          out.reason = "missing/invalid Upgrade"
          return out
        end
        conn = req.req_headers["connection"]
        if icontains(conn, "upgrade") == false
          out.valid = false
          out.reason = "missing/invalid Connection"
          return out
        end

        ver = req.req_headers["sec-websocket-version"]
        if ver != "13"
          out.valid = false
          out.reason = "bad/missing Sec-WebSocket-Version"
          return out
        end

        key = req.req_headers["sec-websocket-key"]
        if key.length == 0
          out.valid = false
          out.reason = "missing Sec-WebSocket-Key"
          return out
        end

        out.valid = true
        out.accept_key = Crypto.sp_crypto_websocket_accept(key)

        # Comma-separated list; the handler picks one and hands it to
        # Driver#set_subprotocol so the 101 can echo it.
        out.protocols = split_csv(req.req_headers["sec-websocket-protocol"])
        out
      end

      # the raw HTTP/1.1 101 bytes that accept the upgrade.
      #
      # @param accept_key [String] the Sec-WebSocket-Accept value from `check`
      # @param protocol [String] the chosen subprotocol; empty omits
      #   Sec-WebSocket-Protocol entirely (§4.2.2), rather than echoing a
      #   subprotocol the server does not implement
      # @return [String] the 101 response bytes, header block included
      def self.build_response(accept_key, protocol)
        out = "HTTP/1.1 101 Switching Protocols\r\n" +
              "Upgrade: websocket\r\n" +
              "Connection: Upgrade\r\n" +
              "Sec-WebSocket-Accept: " + accept_key + "\r\n"
        if protocol.length > 0
          out << "Sec-WebSocket-Protocol: " + protocol + "\r\n"
        end
        out + "\r\n"
      end

      # Case-insensitive substring test: values arrive as sent, so
      # `Connection: keep-alive, Upgrade` must match in any case.
      def self.icontains(hay, needle)
        if hay.length == 0 || needle.length == 0
          return false
        end
        hl = downcase(hay)
        nl = downcase(needle)
        Tep.str_find(hl, nl, 0) >= 0
      end

      def self.downcase(s)
        out = +""
        i = 0
        while i < s.length
          c = s[i]
          if c >= "A" && c <= "Z"
            out << (c.ord + 32).chr
          else
            out << c
          end
          i += 1
        end
        out
      end

      def self.split_csv(s)
        out = [""]
        out.pop
        if s.length == 0
          return out
        end
        pos = 0
        while pos < s.length
          comma = Tep.str_find(s, ",", pos)
          if comma < 0
            out.push(trim(s[pos, s.length - pos]))
            return out
          end
          out.push(trim(s[pos, comma - pos]))
          pos = comma + 1
        end
        out
      end

      def self.trim(s)
        i = 0
        while i < s.length && (s[i] == " " || s[i] == "\t")
          i += 1
        end
        j = s.length - 1
        while j >= i && (s[j] == " " || s[j] == "\t")
          j -= 1
        end
        if j < i
          return ""
        end
        s[i, j - i + 1]
      end

      # Private on purpose: `check` and `build_response` are the entries; the
      # header helpers are free to change without notice.
      private_class_method :icontains, :downcase, :split_csv, :trim

      class Result
        attr_accessor :valid, :reason, :accept_key, :protocols

        def initialize
          @valid      = false
          @reason     = +""
          @accept_key = +""
          @protocols  = [""]
          @protocols.pop
        end
      end
    end
  end
end
