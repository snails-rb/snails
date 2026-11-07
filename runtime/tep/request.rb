require "json"
# Tep::Request — the request as it arrived off the wire: verb, path, query,
# headers, cookies, and body. Tep::Parser fills the header side; the
# servers' body drains complete the body before dispatch.
module Tep
  class Request
    # `MAX_BODY_BYTES` — the transport's own body cap. 8 MiB follows the
    # application-level default Plug/Phoenix uses (8 MB); nginx (1 MiB),
    # Django (2.5 MB), and Express (100 KB) are stricter, ASP.NET Core (30 MB)
    # is looser. A larger Content-Length is refused with 413 before any of it
    # is read, so one client cannot pin a worker by advertising a body the
    # server would hold in memory.
    MAX_BODY_BYTES = 8 * 1024 * 1024

    # `BODY_READ_TIMEOUT` — the whole-body read deadline in seconds. 30s
    # matches Puma's first-data timeout and Gunicorn's worker timeout; Plug's
    # 15s per-read and nginx's 60s per-read bracket it. The deadline covers
    # every recv of one body, not one recv.
    BODY_READ_TIMEOUT = 30

    # The drain answers :ok, :too_large, :timeout, or :incomplete; the server
    # maps the failures to 413, 408, and 400.

    attr_accessor :verb, :path, :raw_path, :http_version
    # `req_params` (not `params`): this holds the wire-side captures and
    # query/form fields, a different thing from the controller's request
    # params (`@_params` behind `ActionController::API#params`). Under
    # spinel two classes sharing an ivar name unify its type, so keeping
    # the two apart by name also keeps this class's String->String reads
    # out of the controller's nested poly hash. Same reasoning as
    # req_headers.
    attr_accessor :req_params, :query, :req_headers, :raw_body, :cookies
    # `raw_query` — the query string as it arrived; `body_fields` — the
    # body's fields by name (multipart text parts, and JSON leaves
    # flattened the same way). `Snails::Main.request_params` builds the
    # controller's params from both
    # (runtime/action_dispatch/param_builder.rb), because the flat
    # hashes declared above keep only a repeated key's last value and
    # cannot say `ids[]=1&ids[]=2`.
    #
    # @return [String, Hash{String => String}] the raw query string, then
    #   the body's fields
    attr_accessor :raw_query, :body_fields
    attr_accessor :remote_host
    attr_accessor :ivars

    def initialize
      @verb         = +""
      @path         = +""
      @raw_path     = +""
      @http_version = "HTTP/1.0"
      @req_params       = Tep.str_hash   # path captures + query + form merged
      @query        = Tep.str_hash   # raw query string only
      @raw_query    = +""
      @body_fields  = Tep.str_hash
      @req_headers  = Tep.str_hash   # downcased names; not shared with Response
      @cookies      = Tep.str_hash   # parsed from Cookie: header
      @raw_body     = +""
      @remote_host  = +""
      @passed       = false          # `pass` flag: skip to the next matching route
      @ivars        = Tep.str_hash   # per-request bag for handler-owned values
      # File parts of a multipart body, by full field name
      # (`message[attachment]`); the text parts join @req_params. The typed
      # String hash cannot hold a file, so the two travel apart and
      # `Snails::Main.request_params` folds both into the controller's
      # params.
      @uploads      = {}
      # Set by `parse_body_params` when the body does not parse — see
      # `body_parse_failed?`
      @body_parse_failed = false
    end

    attr_accessor :passed
    attr_accessor :uploads
    def set_passed; @passed = true; end

    # `req.raw_body` is the canonical body reader: a `req.body` alias
    # would collide with controller#body through spinel's polymorphic
    # dispatch.

    # `keep_alive?()` — whether the connection stays open after this
    # response. Spinel's Hash[k] returns "" for a missing string key
    # rather than nil, so an empty Connection header reads the same as
    # no header at all; both mean "use the HTTP/1.1 default".
    #
    # @return [Boolean] false on `Connection: close`, true on
    #   `Connection: keep-alive`, otherwise the HTTP/1.1 default (true
    #   for HTTP/1.1, false for HTTP/1.0)
    def keep_alive?
      lc = @req_headers["connection"].downcase
      if lc == "close"
        return false
      end
      if lc == "keep-alive"
        return true
      end
      @http_version == "HTTP/1.1"
    end

    # `content_length()` — the advertised body length in bytes. The parser
    # rejects a non-digit or duplicated header, so a value here is a run of
    # ASCII digits. The parse clamps at `MAX_BODY_BYTES + 1`: a larger body is
    # refused before reading, and the clamp keeps a very long digit run from
    # overflowing the parse. A non-digit value fails closed to the same
    # sentinel rather than silently reading as zero.
    #
    # @return [Integer] the body length, capped at MAX_BODY_BYTES + 1
    def content_length
      v = @req_headers["content-length"]
      n = 0
      i = 0
      while i < v.length
        b = v.getbyte(i)
        return MAX_BODY_BYTES + 1 if b < 48 || b > 57
        n = n * 10 + (b - 48)
        return MAX_BODY_BYTES + 1 if n > MAX_BODY_BYTES
        i += 1
      end
      n
    end

    def form?
      @req_headers["content-type"].downcase.start_with?("application/x-www-form-urlencoded")
    end

    # `multipart?()` — whether the body arrived as multipart/form-data,
    # the encoding a form with file inputs sends. It is parsed by
    # `ActionDispatch::Http::Multipart`
    # (runtime/action_dispatch/multipart.rb): text parts into
    # @req_params, file parts into @uploads.
    #
    # @return [Boolean] true when the Content-Type is
    #   multipart/form-data
    def multipart?
      @req_headers["content-type"].downcase.start_with?("multipart/form-data")
    end

    # `json?()` — whether the body arrived as JSON, the encoding a
    # client sends when it asks for `contentType: "application/json"`.
    #
    # @return [Boolean] true when the Content-Type is application/json;
    #   `parse_body_params` below parses such a body into params
    def json?
      @req_headers["content-type"].downcase.start_with?("application/json")
    end

    # `body_parse_failed?()` — whether the body arrived in a shape the
    # runtime could not read: JSON that does not parse or that is not an
    # object, or a multipart body with no boundary or one that stops
    # part-way. `Snails::Main.dispatch` turns it into a 400, so a broken
    # payload is refused instead of running the action against the empty
    # params a half-read body would leave behind.
    #
    # @return [Boolean] true when `parse_body_params` could not read the body
    def body_parse_failed?
      @body_parse_failed
    end

    # ---- Header readers (reads only; no `.ip` yet) ----
    # Convenience getters over headers already parsed above. `.ip` needs a
    # peer-address C helper first, so it is deferred.

    def host;          @req_headers["host"];        end
    def user_agent;    @req_headers["user-agent"];  end
    def referer;       @req_headers["referer"];     end
    def referrer;      @req_headers["referer"];     end   # alternate spelling
    def accept;        @req_headers["accept"];      end
    def content_type;  @req_headers["content-type"]; end

    # `scheme()` — the scheme this connection sees from the client's
    # view (`ssl?` reads it too). Tep does not terminate TLS itself, so
    # the answer comes off the `X-Forwarded-Proto` header a reverse proxy
    # sets.
    #
    # @return [String] the forwarded proto, downcased, or "http" when the
    #   header is absent
    def scheme
      proto = @req_headers["x-forwarded-proto"]
      if proto.length > 0
        return proto.downcase
      end
      "http"
    end

    def ssl?
      scheme == "https"
    end

    # `drain_body(limit)` — the one body-read policy every server shares:
    # refuse a body over `MAX_BODY_BYTES` before reading, give the whole body
    # one `BODY_READ_TIMEOUT` deadline, and answer a finite outcome. The block
    # owns only the transport-specific wait and read: it receives the
    # remaining seconds and the maximum byte count, and returns the next chunk
    # or nil when its wait timed out.
    #
    # @param limit [Integer] the advertised Content-Length
    # @return [Symbol] :ok, :too_large, :timeout, or :incomplete
    def drain_body(limit)
      # bytesize, not length: Content-Length counts bytes, and a body
      # carrying multibyte UTF-8 reads short on characters — leaving the
      # tail unread on the socket, where it corrupts the next keep-alive
      # request.
      already = @raw_body.bytesize
      if limit > MAX_BODY_BYTES || already > MAX_BODY_BYTES
        return :too_large
      end
      deadline_us = Sock.sphttp_now_us + BODY_READ_TIMEOUT * 1000000
      while already < limit
        remaining_seconds = (deadline_us - Sock.sphttp_now_us) / 1000000.0
        if remaining_seconds <= 0
          return :timeout
        end
        chunk = yield(remaining_seconds, limit - already)
        return :timeout if chunk.nil?
        return :incomplete if chunk.bytesize == 0
        @raw_body = @raw_body + chunk
        already = @raw_body.bytesize
      end
      :ok
    end

    # `parse_body_params()` — put the body's fields into @req_params:
    # urlencoded pairs, multipart text parts (file parts go to @uploads),
    # or a JSON object flattened by `flatten_json`. The two body drains
    # share it; they differ only in how they wait for bytes.
    #
    # A body it cannot read sets `body_parse_failed?` instead of keeping
    # whatever it managed to read: the dispatcher answers 400, and the
    # fields before the break are not the request the client meant.
    #
    # @return [void]
    def parse_body_params
      if form?
        Url.parse_query(@raw_body).each do |k, v|
          @req_params[k] = v
        end
      elsif multipart?
        form = ActionDispatch::Http::Multipart.parse(@raw_body, @req_headers["content-type"])
        if form.nil?
          @body_parse_failed = true
        else
          form.fields.each do |k, v|
            @req_params[k] = v
            @body_fields[k] = v
          end
          form.files.each do |k, v|
            @uploads[k] = v
          end
        end
      elsif json? && @raw_body.length > 0
        begin
          parsed = JSON.parse(@raw_body)
          if parsed.is_a?(Hash)
            flatten_json(parsed, "")
          else
            # A JSON body that is not an object has no field names to read,
            # so there is nothing to build params from.
            @body_parse_failed = true
          end
        rescue JSON::ParserError
          @body_parse_failed = true
        end
      end
    end

    # `flatten_json(value, prefix)` — a parsed JSON object into
    # @req_params and @body_fields, spelled the way a form posts it:
    # `{"blob": {"filename": "a.png"}}` becomes `blob[filename]`, the key
    # shape `Snails::Main.request_params` already nests from a multipart
    # body's fields. Scalars arrive as `to_s`, null as "".
    #
    # An array has no slot in either flat hash: its elements are walked
    # into the same `prefix[]` key, so the last one wins.
    #
    # @param prefix [String] the key path built so far ("" at the top)
    # @return [void]
    def flatten_json(value, prefix)
      if value.is_a?(Hash)
        value.each do |k, v|
          key = prefix.length == 0 ? k.to_s : prefix + "[" + k.to_s + "]"
          flatten_json(v, key)
        end
      elsif value.is_a?(Array)
        value.each { |element| flatten_json(element, "#{prefix}[]") }
      elsif value.nil?
        @req_params[prefix] = +""
        @body_fields[prefix] = +""
      else
        @req_params[prefix] = value.to_s
        @body_fields[prefix] = value.to_s
      end
    end

    # `consume_body_via_scheduler(client_fd)` — the body drain for
    # Tep::Server::Scheduled, whose client fd is non-blocking: a blocking
    # recv would starve the whole loop. `Tep::Scheduler.io_wait` parks this
    # fiber between reads so other connections keep running.
    #
    # @param client_fd [Integer] the accepted connection fd
    # @return [Symbol] :ok, :too_large, :timeout, or :incomplete
    def consume_body_via_scheduler(client_fd)
      outcome = drain_body(content_length) do |remaining_seconds, max_bytes|
        if Tep::Scheduler.io_wait(client_fd, Tep::Scheduler::READ, remaining_seconds) == 0
          nil
        else
          Sock.sphttp_recv_some(client_fd, max_bytes)
        end
      end
      parse_body_params if outcome == :ok
      outcome
    end

    # `consume_body_via_io(io, client_fd)` — the body drain for
    # Tep::Server::Threaded, whose client fd is non-blocking: `io` is the
    # connection's `IO.for_fd` wrapper, and its timed `wait_readable`
    # parks this green thread until body bytes arrive.
    #
    # @param io [IO] the connection's file wrapper
    # @param client_fd [Integer] the accepted connection fd
    # @return [Symbol] :ok, :too_large, :timeout, or :incomplete
    def consume_body_via_io(io, client_fd)
      outcome = drain_body(content_length) do |remaining_seconds, max_bytes|
        if io.wait_readable(remaining_seconds).nil?
          nil
        else
          Sock.sphttp_recv_some(client_fd, max_bytes)
        end
      end
      parse_body_params if outcome == :ok
      outcome
    end

    # Private on purpose: the three consume methods are the entries; the
    # shared policy loop is free to change without notice.
    private :drain_body
  end
end
