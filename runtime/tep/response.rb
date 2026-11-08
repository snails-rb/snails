# Tep::Response — what the handler writes back: a status, string-keyed
# headers, a body, and the WebSocket / streaming slots. The framework adds
# Content-Length and Connection when serializing.
module Tep
  class Response
    attr_accessor :status, :headers, :body, :halted, :file_path, :set_cookies

    # the framing decision for HTTP HEAD: the write paths send the status and
    # headers (Content-Length computed from `body`) and no message body.
    # `Tep::App#dispatch` sets it at the seam every server passes through, so
    # this class carries the rule and the write paths only obey it — a client
    # reads no body from a HEAD response, so bytes written anyway would be taken
    # for the next response on a keep-alive connection.
    attr_accessor :headers_only

    def initialize
      @status      = 200
      @headers     = Tep.str_hash
      @body        = +""
      @halted      = false
      @file_path   = +""
      # `Set-Cookie` is a header that can repeat, so it cannot live in a
      # single Hash slot. Each entry is one fully-formatted Set-Cookie line,
      # emitted verbatim by the writer.
      @set_cookies = [""]
      # pop, not clear/delete_at: the type-seed removal idiom hits a
      # per-(method x representation) arm matrix in spinel's shared-string
      # machinery, and pop is armed for every representation this ivar
      # takes. clear and delete_at each have an unarmed cell.
      @set_cookies.pop
      @streamer    = Streamer.new   # default no-op; only used when @streaming
      @streaming   = false
      # WebSocket upgrade slots. When @upgrading_ws is set (by
      # start_websocket, from the /cable handler), Tep::Server::Threaded's
      # write path emits the 101 Switching Protocols handshake and then
      # drives Tep::WebSocket::Connection's recv loop instead of writing a
      # normal body.
      @upgrading_ws  = false
      @ws_accept_key = +""
      @ws_driver     = Tep::WebSocket::Driver.new(0)
      @headers_only  = false
    end

    attr_accessor :streamer, :streaming
    attr_accessor :upgrading_ws, :ws_accept_key, :ws_driver

    def start_stream(streamer)
      @streamer  = streamer
      @streaming = true
    end

    # mark the response as a WebSocket upgrade. The server writes a 101
    # Switching Protocols response with the accept key, assigns the live client
    # fd onto the driver, then runs the recv loop.
    #
    # @param accept_key [String] the Sec-WebSocket-Accept value
    # @param driver [Tep::WebSocket::Driver] the driver the recv loop
    #   drives
    # @return [void]
    def start_websocket(accept_key, driver)
      @upgrading_ws  = true
      @ws_accept_key = accept_key
      @ws_driver     = driver
    end

    # append one Set-Cookie line.
    #
    # @param opts [Hash{String => String}] option name to value: path,
    #   expires, max-age, domain, samesite, httponly, secure. An empty
    #   hash writes just "name=value"; a flag option with an empty value
    #   is written bare (HttpOnly, Secure).
    # @return [void]
    def set_cookie(name, value, opts)
      line = name + "=" + Url.escape(value)
      if opts.length > 0
        opts.each do |k, v|
          if v.length == 0
            line << "; " + k          # bare flag (HttpOnly, Secure)
          else
            line << "; " + k + "=" + v
          end
        end
      end
      @set_cookies.push(line)
    end

    def send_file(path)
      @file_path = path
      @body = +""
    end

    # install the body when it is still empty.
    #
    # The assignment cannot be spelled `res.body = x` from a context
    # holding a polymorphic value: spinel's polymorphic-receiver write
    # codegen emits a no-op there, so the write goes through this method,
    # where `self` is unambiguously Response.
    #
    # @param s [String] the body to install
    # @return [void]
    def set_body_if_empty(s)
      if @body.length == 0 && s.length > 0
        @body = s
      end
    end

    def set_status(n); @status = n; end

    def halted_close?
      @halted && @status >= 300
    end
  end
end
