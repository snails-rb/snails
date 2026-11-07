# Percent-decoding and form-urlencoded parsing: the wire-side counterpart of
# the query/form handling in Tep::Request. Also the percent-encoder for
# cookie values (Tep::Response#set_cookie).
module Tep
  class Url
    # `unescape(s)` — percent-decode form-urlencoded text: "%XX" bytes, with
    # "+" read as a space.
    #
    # Decoding is BY BYTE, and the result is tagged UTF-8: a percent-encoded
    # multibyte character comes back as text, not as an ASCII-8BIT byte string.
    #
    # @param s [String] the encoded text
    # @return [String] the decoded text, tagged UTF-8; an incomplete or non-hex
    #   escape stays literal
    # @example
    #   Tep::Url.unescape("%41+b")  # => "A b"
    def self.unescape(s)
      out = +""
      i = 0
      n = s.bytesize
      while i < n
        b = s.getbyte(i)
        if b == 0x2B # "+"
          out << " "
          i += 1
        elsif b == 0x25 && i + 2 < n # "%"
          hi = hex_nibble(s.getbyte(i + 1))
          lo = hex_nibble(s.getbyte(i + 2))
          if hi >= 0 && lo >= 0
            out << ((hi * 16 + lo).chr)
            i += 3
          else
            out << b.chr
            i += 1
          end
        else
          out << b.chr
          i += 1
        end
      end
      out.force_encoding("UTF-8")
    end

    # `escape(s)` — percent-encode the bytes unsafe in cookie values, query
    # strings, and similar contexts.
    #
    # Encoding is BY BYTE, so a multi-byte character round-trips through
    # `unescape`; a space is `%20`, not `+`, because `unescape` reads `+` back
    # as a space (a literal one has to arrive as `%2B`).
    #
    # @param s [String] the text to encode
    # @return [String] the text with every byte outside the RFC 3986 unreserved
    #   set (ALPHA / DIGIT / `-._~`) written as `%XX` in uppercase hex
    def self.escape(s)
      out = +""
      i = 0
      n = s.bytesize
      while i < n
        b = s.getbyte(i)
        if (b >= 0x61 && b <= 0x7A) || (b >= 0x41 && b <= 0x5A) ||
           (b >= 0x30 && b <= 0x39) || b == 0x2D || b == 0x2E ||
           b == 0x5F || b == 0x7E
          out << b.chr
        else
          out << "%" + hex_char(b / 16) + hex_char(b % 16)
        end
        i += 1
      end
      out
    end

    # `split_url(u)` — split a URL into a Hash keyed by "scheme", "host",
    # "port", "path" and "query".
    #
    # Recognises `http://host[:port]/path?query` and the same shape with
    # `https://`. Without a scheme the input is treated as a path (host stays
    # empty), so relative paths route through the same parser. Default ports
    # follow the scheme: 80 for http, 443 for https. Path defaults to "/".
    #
    # One method on purpose: spinel's analyzer widens Hash-typed parameters
    # when a helper mutates them and the caller then keeps reading, so a
    # single body keeps `out` narrowed to StrStrHash throughout.
    #
    # @param u [String] the URL or path to split
    # @return [Hash{String => String}] "scheme", "host", "port", "path" and
    #   "query" — `query` is the raw substring after "?", undecoded
    def self.split_url(u)
      out = Tep.str_hash
      out["scheme"] = +""
      out["host"]   = +""
      out["port"]   = +""
      out["path"]   = "/"
      out["query"]  = +""

      rest = u
      if rest.length >= 7 && rest[0, 7] == "http://"
        out["scheme"] = "http"
        out["port"]   = "80"
        rest = rest[7, rest.length - 7]
      elsif rest.length >= 8 && rest[0, 8] == "https://"
        out["scheme"] = "https"
        out["port"]   = "443"
        rest = rest[8, rest.length - 8]
      end

      if out["scheme"].length > 0
        slash = rest.index("/")
        hostport = rest
        tail     = "/"
        unless slash.nil?
          hostport = rest[0, slash]
          tail     = rest[slash, rest.length - slash]
        end
        colon = hostport.index(":")
        if colon.nil?
          out["host"] = hostport
        else
          out["host"] = hostport[0, colon]
          out["port"] = hostport[colon + 1, hostport.length - colon - 1]
        end
        rest = tail
      end

      qi = rest.index("?")
      if qi.nil?
        out["path"] = rest
      else
        out["path"]  = rest[0, qi]
        out["query"] = rest[qi + 1, rest.length - qi - 1]
      end
      if out["path"].length == 0
        out["path"] = "/"
      end
      out
    end

    # `parse_query(s)` — parse a query string into a name-keyed Hash.
    #
    # @param s [String] the raw query string, without the leading "?"
    # @return [Hash{String => String}] one entry per "&"-separated pair, names
    #   and values percent-decoded; a pair with no "=" maps to "", and a name
    #   the input never carried reads ""
    # @example
    #   Tep::Url.parse_query("a=1&b=2&c")  # => {"a"=>"1","b"=>"2","c"=>""}
    def self.parse_query(s)
      h = Tep.str_hash
      if s.length == 0
        return h
      end
      pairs = s.split("&")
      pairs.each do |pair|
        if pair.length > 0
          eq = pair.index("=")
          if eq.nil?
            h[Url.unescape(pair)] = +""
          else
            k = pair[0, eq]
            v = pair[eq + 1, pair.length - eq - 1]
            h[Url.unescape(k)] = Url.unescape(v)
          end
        end
      end
      h
    end

    # Private on purpose: `escape` and `unescape` are the entries; the
    # hex helpers are free to change without notice.

    def self.hex_char(n)
      if n < 10
        return ("0".bytes[0] + n).chr
      end
      ("A".bytes[0] + n - 10).chr
    end

    def self.hex_nibble(b)
      return b - 0x30 if b >= 0x30 && b <= 0x39 # "0".."9"
      return b - 0x57 if b >= 0x61 && b <= 0x66 # "a".."f"
      return b - 0x37 if b >= 0x41 && b <= 0x46 # "A".."F"
      -1
    end
    private_class_method :hex_char, :hex_nibble
  end
end
