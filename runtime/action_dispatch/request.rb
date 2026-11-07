# The request object controllers, filters, and helpers reach — named
# `ActionDispatch::Request`, with typed fields the dispatcher assigns from its
# transport (Tep): per-field types keep every read concrete under AOT. The
# internal env hash holds request headers in Rack-style keys; `headers` is the
# read-only view over it.
module ActionDispatch
  # `request.body` — the raw body as an IO, not the String. Callers rewind and
  # read it (`request.body.rewind; request.body.read`), which a String cannot
  # answer. The bytes Tep read are the storage; this is the cursor over them,
  # exposing the subset of Rack's input a controller reaches: `rewind`, `read`,
  # `string`, `size`, `eof?`.
  #
  # Not `StringIO`: a request body needs one method each, not a stdlib class.
  class RequestBody
    def initialize(text)
      @text = text
      @pos = 0
    end

    # `string` — the whole body as a String, whatever the cursor says —
    # Rack's `StringIO#string`, and what `raw_post` is built on.
    #
    # @return [String] the entire body, cursor position ignored
    def string
      @text
    end

    def rewind
      @pos = 0
    end

    # `read` — from the cursor to the end, as Ruby's `IO#read` with no
    # length; a second read at the end is "" (not nil — that is the
    # `read(length)` form's answer, which no caller here spells). The
    # cursor counts characters, not bytes: only the whole-body read is
    # served, so the two agree on everything a caller can observe.
    #
    # @return [String] the remaining body, "" once it has all been read
    def read
      out = @text[@pos, @text.length - @pos].to_s
      @pos = @text.length
      out
    end

    def size
      @text.bytesize
    end

    def length
      @text.bytesize
    end

    def eof?
      @pos >= @text.length
    end
  end

  # `ActionDispatch::TestRequest.create(env)` — the Request a test builds by
  # hand from a Rack env rather than from a transport. One per request shape,
  # which is why it is not in the shared test harness: `create` maps the env
  # keys the accessor-backed class below models and leaves the rest in the
  # internal env hash, where `headers` reads them.
  #
  # The class's `initialize` supplies what the env omits — "localhost", "/",
  # GET — so a test that names only a host gets an otherwise ordinary request.
  module TestRequest
    # NO DEFAULT on `env`: every caller names an env — a `TestRequest` with
    # no env is a `Request.new`.
    def self.create(env)
      r = Request.new(env)
      env.each do |k, value|
        if k == "HTTP_HOST"
          r.host = value.to_s
        elsif k == "PATH_INFO"
          r.path = value.to_s
        elsif k == "REQUEST_METHOD"
          r.request_method = value.to_s
        elsif k == "QUERY_STRING"
          r.query_string = value.to_s
        elsif k == "SCRIPT_NAME"
          r.script_name = value.to_s
        elsif k == "HTTP_REFERER"
          r.referer = value.to_s
        elsif k == "REMOTE_ADDR"
          r.remote_ip = value.to_s
        end
      end
      r
    end
  end

  class Request
    attr_accessor :remote_ip
    attr_accessor :path
    attr_accessor :query_string
    # `script_name` — Rack's SCRIPT_NAME: the prefix the app is mounted
    # under, "" at the root; absolute URLs built from a request include it.
    #
    # @return [String] the mount prefix, "" at the root
    attr_accessor :script_name
    attr_accessor :request_method
    attr_accessor :referer
    attr_accessor :host
    attr_reader :format

    # `initialize(env = nil)` — a fresh request; the optional env hash is
    # copied into the internal header store. Callers never receive the hash
    # back — `headers` is the read-only view.
    #
    # @param env [Hash{String => untyped}, nil] the Rack-style header bag
    # @return [void]
    def initialize(env = nil)
      @remote_ip = "127.0.0.1"
      @path = "/"
      @query_string = +""
      @script_name = +""
      @request_method = "GET"
      @referer = +""
      @host = "localhost"
      @format = "html"
      @body = +""
      @body_io = nil
      # The header store. Not a public accessor: apps read `headers`.
      @env = {}
      env.each { |k, v| @env[k] = v } unless env.nil?
      @headers = nil
      # The `@params` slot is initialized for the same kind of reason:
      # `Request.for` copies into it (`params.each { |k, v| r.params[k] = v }`),
      # which READS the slot before anything writes it. Unset, that read is nil
      # on an interpreted run and a null pointer under spinel AOT — the write
      # then dereferences it and the test binary segfaults with no output.
      #
      # Every ivar this class declares gets a value here, or the AOT test
      # binary dies on the read.
      @params = {}
      # Declared in the .rbs, so it needs the same initialized value.
      @user_agent = +""
    end

    # `format=` — the writer accepts a symbol (`request.format = :json`)
    # and stores the canonical string.
    #
    # @param value [Object] the format, as a Symbol or a String
    # @return [String] the stored format
    def format=(value)
      @format = value.to_s
    end

    # `body=` — the body the transport (or the test harness) hands over
    # is a String; what a controller reads back is the IO over it. A
    # fresh write drops the old cursor, so a body assigned twice — the
    # harness re-posting through one Request — starts at 0 again.
    #
    # @param value [String] the raw request body
    # @return [String] the stored body
    def body=(value)
      @body = value
      @body_io = nil
      value
    end

    def body
      @body_io = RequestBody.new(@body) if @body_io.nil?
      @body_io
    end

    # `raw_post` — the body as one String, cursor untouched.
    #
    # @return [String] the whole body, cursor position ignored
    def raw_post
      @body
    end

    def get?
      @request_method == "GET"
    end

    # `head?` — did the client send HEAD? It sits beside `get?` because
    # the safe-request idiom is `request.get? || request.head?`; a filter
    # that names the predicate must find the method.
    #
    # @return [Boolean] true when the request method is HEAD
    def head?
      @request_method == "HEAD"
    end

    def xhr?
      @env.fetch("HTTP_X_REQUESTED_WITH", "").to_s == "XMLHttpRequest"
    end

    # `fullpath` — the path with its query string attached, the part an
    # absolute URL keeps after the host.
    #
    # @return [String] `path`, plus `?query` when a query string is set
    def fullpath
      if @query_string == ""
        @path
      else
        @path + "?" + @query_string
      end
    end

    # `ssl?` — did the client connect over TLS? The server says so
    # (`HTTPS=on`), or a proxy that terminated TLS in front of us says so
    # in `X-Forwarded-Proto` — a load balancer or a PaaS router. The
    # header is honored without configuration, so a request behind such a
    # proxy builds https URLs rather than mixed-content http ones.
    #
    # @return [Boolean] true when the request arrived over TLS
    def ssl?
      return true if @env.fetch("HTTPS", "").to_s == "on"
      forwarded = @env.fetch("HTTP_X_FORWARDED_PROTO", "").to_s
      forwarded.split(",").first.to_s.strip.downcase == "https"
    end

    # `protocol` — the scheme WITH its `://`.
    #
    # @return [String] "https://" or "http://"
    def protocol
      ssl? ? "https://" : "http://"
    end

    # `base_url` — scheme + host, no path: the base an absolute URL
    # builds on.
    #
    # @return [String] the scheme and host, without a path
    def base_url
      protocol + @host
    end

    # `original_url` — the absolute URL of this request.
    #
    # @return [String] scheme, host, path, and query
    def original_url
      base_url + fullpath
    end

    # `url` — the absolute URL, the name app code reaches for (a login
    # filter stores it as the post-login return path). Its own method
    # rather than an alias.
    #
    # @return [String] the absolute URL, the same value as `original_url`
    def url
      original_url
    end

    def referrer
      @referer
    end

    # `user_agent` — the User-Agent header, recorded on session rows and
    # read by bot filters.
    #
    # @return [String] the header value, "" when the request carried none
    def user_agent
      @user_agent
    end

    def user_agent=(value)
      @user_agent = value
    end

    # `headers` — the request headers as a read-only, case-insensitive view.
    # Header names map to the internal Rack-style keys (`Authorization` →
    # `HTTP_AUTHORIZATION`, `Content-Type` → `CONTENT_TYPE`).
    #
    # @return [ActionDispatch::Http::Headers] the header view
    # @example
    #   request.headers["Authorization"]
    def headers
      @headers ||= ActionDispatch::Http::Headers.new(@env)
    end

    # `params` — the request params, keyed by String.
    #
    # @return [Hash{String => Object}] the request params
    def params
      @params
    end

    def params=(value)
      @params = value
    end

    # `for(env, params = {})` — build a request from a Rack-shaped env
    # hash, the test harness entry point so a controller test gets a real
    # `controller.request` instead of nil.
    #
    # @param env [Hash{String => untyped}] the Rack-shaped env the request
    #   fields are read from
    # @param params [Hash{String => untyped}] the request params; keys are
    #   stringified
    # @return [Request] the built request
    def self.for(env, params = {})
      # `initialize` copies the env into the wide `@env` slot; a caller's
      # narrow literal never lands there directly.
      r = new(env)
      # The params hash is copied because its own default is an empty literal:
      # a bare `{}` is Symbol-keyed, which is not what `@params` is declared to
      # hold. `k.to_s` bridges both the default and a Symbol-keyed caller.
      params.each { |k, v| r.params[k.to_s] = v }
      # Every read calls `.to_s`: the constructor parameter holds `untyped` BY
      # CONTRACT, so a read is a dynamic value, and these attributes are
      # Strings. An interpreted run coerces on assignment and never mentions
      # it; spinel refuses the assignment outright. The `|| default` still
      # supplies the value for a missing key — `nil.to_s` is `""`, not the
      # default.
      r.request_method = (env["REQUEST_METHOD"] || "GET").to_s
      r.path = (env["PATH_INFO"] || "/").to_s
      r.query_string = (env["QUERY_STRING"] || "").to_s
      r.script_name = (env["SCRIPT_NAME"] || "").to_s
      r.host = (env["HTTP_HOST"] || env["SERVER_NAME"] || "localhost").to_s
      r.remote_ip = (env["REMOTE_ADDR"] || "127.0.0.1").to_s
      r.referer = (env["HTTP_REFERER"] || "").to_s
      r.user_agent = (env["HTTP_USER_AGENT"] || "").to_s
      r
    end
  end
end
