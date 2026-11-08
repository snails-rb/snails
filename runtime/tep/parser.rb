# HTTP/1.x request parser. Produces a Tep::Request from the raw byte blob
# the server read off the wire (headers, possibly a prefix of the body).
module Tep
  class Parser
    # turn one raw read off the wire into a Request.
    #
    # @param blob [String] the bytes the server read from the socket
    # @return [Tep::Request, nil] the parsed request, or nil when the
    #   blob is malformed
    def self.parse(blob)
      # String#index returns nil (not -1) when not found, so every lookup
      # below needs an explicit nil guard.
      end_of_headers = blob.index("\r\n\r\n")
      if end_of_headers.nil?
        return nil
      end
      headers_blob = blob[0, end_of_headers]
      lines = headers_blob.split("\r\n")
      if lines.length == 0
        return nil
      end

      first = lines[0]
      first_parts = first.split(" ")
      if first_parts.length < 3
        return nil
      end

      req = Request.new
      req.verb         = first_parts[0]
      req.raw_path     = first_parts[1]
      req.http_version = first_parts[2]

      qmark = req.raw_path.index("?")
      if qmark.nil?
        req.path = req.raw_path
      else
        req.path  = req.raw_path[0, qmark]
        qstring   = req.raw_path[qmark + 1, req.raw_path.length - qmark - 1]
        req.query = Url.parse_query(qstring)
        req.raw_query = qstring
      end

      content_length_seen = false
      i = 1
      while i < lines.length
        line = lines[i]
        # A folded header line (obs-fold) or a line without a colon is
        # malformed, not a header this parser can ignore: an upstream proxy
        # may read the folded remainder as part of the previous value, which
        # is another way to disagree about body framing.
        if line.start_with?(" ") || line.start_with?("\t")
          return nil
        end
        colon = line.index(":")
        if colon.nil?
          return nil
        end
        name  = line[0, colon].downcase
        if !header_name_valid?(name)
          return nil
        end
        value = line[colon + 1, line.length - colon - 1].strip
        # Request-smuggling defenses. Tep frames bodies by Content-Length
        # only, so a Transfer-Encoding (chunked included) is refused rather
        # than ignored: an upstream proxy that honours it would split the
        # stream differently than this parser. A duplicate or non-digit
        # Content-Length is ambiguous in the same way, so the last value
        # must not silently win.
        if name == "transfer-encoding"
          return nil
        end
        if name == "content-length"
          if content_length_seen || !digits_only?(value)
            return nil
          end
          content_length_seen = true
        end
        req.req_headers[name] = value
        i += 1
      end

      # Pre-merge query into params; path captures are folded in by the
      # router on a successful match.
      req.query.each do |k, v|
        req.req_params[k] = v
      end

      # Parse Cookie header into req.cookies. Format: "k=v; k2=v2; ...".
      # Whitespace around `;` is allowed and stripped.
      cookie_blob = req.req_headers["cookie"]
      if cookie_blob.length > 0
        cookie_blob.split(";").each do |pair|
          eq = pair.index("=")
          if !eq.nil? && eq > 0
            cname  = pair[0, eq].strip
            cvalue = pair[eq + 1, pair.length - eq - 1].strip
            req.cookies[cname] = Url.unescape(cvalue)
          end
        end
      end

      # Carry over any body bytes already in the blob: one recv() may have
      # read past the headers.
      body_start = end_of_headers + 4
      if body_start < blob.length
        req.raw_body = blob[body_start, blob.length - body_start]
      end

      # More bytes than the advertised body is either a pipelined request
      # (Tep does not pipeline) or a parameter-smuggling attempt: a proxy that
      # frames by Content-Length would not pass the extra bytes, while this
      # parser would put them into params. Refuse instead of reading past the
      # declared boundary.
      if req.raw_body.bytesize > req.content_length
        return nil
      end

      req
    end

    # whether a downcased header name can be used as one header's key. An empty
    # name or one carrying whitespace or a control byte is refused:
    # `Content-Length : 5` would otherwise read as a different header here than
    # at the proxy, which is a framing ambiguity.
    #
    # @param name [String] the downcased name before the colon
    # @return [Boolean] true for a non-empty name with no whitespace/control
    def self.header_name_valid?(name)
      return false if name.length == 0
      i = 0
      while i < name.length
        b = name.getbyte(i)
        return false if b <= 32 || b == 127
        i += 1
      end
      true
    end
    private_class_method :header_name_valid?

    # whether every byte is an ASCII digit. Content-Length is the one header
    # parsed as a number; a sign, space, or comma would make `.to_i` accept a
    # value an upstream proxy reads differently.
    #
    # @param s [String] the stripped header value
    # @return [Boolean] true for a non-empty run of ASCII digits
    def self.digits_only?(s)
      return false if s.length == 0
      i = 0
      while i < s.length
        b = s.getbyte(i)
        return false if b < 48 || b > 57
        i += 1
      end
      true
    end
    private_class_method :digits_only?
  end
end
