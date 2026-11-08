# The JSON encoder `render json:` runs, required beside its consumer: a tree
# that loads the runtime without the boot chain still resolves
# `ActionController::JsonRender`.
require_relative "json_render"
# Status symbols resolve through the shared protocol table, required beside
# its consumer for the same boot-chain-free reason.
require_relative "../snails/utils"

module ActionController
  # The content type `render json:` answers when the caller names none —
  # byte-identical to the scaffold's `JSON_TYPE` literal, so moving a call to
  # `render json:` keeps the header unchanged.
  JSON_CONTENT_TYPE = "application/json; charset=utf-8"

  # What `json:` holds when the caller passed no `json:` keyword. Ruby cannot
  # express "keyword omitted", so absence rides a dedicated object rather
  # than nil: `render json: nil` must still encode to `null`, while a bare
  # `render()` must fail loudly. Nothing a caller can pass equals it, so no
  # payload's `==` hijacks the test.
  JSON_NOT_GIVEN = Object.new

  # The controller base class: per-request state (params) and response state
  # (status, body, location). The action dispatch (`process_action`) and the
  # before_action filter chain live here; subclasses define their actions and
  # filter registrations.
  class API
    attr_accessor :request_method, :request_path, :request_format

    # the request params an action reads (`params["id"]`). The value lives in
    # `@_params`, outside the app-subclass namespace: an app-side `@params` is a
    # mistake, not a second handle on request state. The scaffold contract
    # (`verify-scaffold`) rejects `@params` in app code, and reading through the
    # accessor lets the value change shape later without touching call sites.
    #
    # The values are the request's scalars, arrays, hashes, and uploaded
    # files; a key carried without a value is nil. The tree is a mutable
    # plain Hash, so the accessor stays untyped.
    #
    # @return [Hash{String => untyped}] the request params
    # @example
    #   params["id"]   # => "42"
    def params
      @_params
    end

    def params=(value)
      @_params = value
    end

    # the current action: the run-time context the `only:`/`except:` gate reads.
    # The action dispatch sets it before `run_before_filters`. Nil before any
    # dispatch set it, and a conditional filter run without it raises rather
    # than silently applying to every action (or none).
    #
    # @return [Symbol?] the action the controller is dispatching
    # @param value [Symbol?] the action to gate conditional filters
    #   against
    attr_accessor :action_name
    # true when the request's Accept is a bare `*/*`, an XMLHttpRequest or fetch
    # that named none, which reads as "any format". The dispatcher sets it;
    # false keeps every other request on the html path.
    #
    # @return [Boolean] true when the request accepted any format
    attr_accessor :accepts_any_format
    # the matched route's own segments (`{"length" => "1y"}` on `/top/1y`), not
    # the query string. The dispatcher assigns it; a caller building a URL from
    # options reads it back to fill a segment the options leave out.
    #
    # @return [Hash{String => String}] the matched route's segments
    attr_accessor :path_parameters
    attr_reader   :status, :body, :location, :content_type
    # Cache-Control as two typed readers rather than one mixed Hash: an
    # Integer and a boolean in one container leaves every subscript with a
    # union type for the compiler to infer. The test harness re-assembles
    # the Hash shape (`ActionResponse#cache_control`), the only reader that
    # wants the subscript spelling.
    attr_reader   :cache_control_max_age, :cache_control_public

    def initialize
      @_params = {}
      @path_parameters = {}
      @status  = 200
      @body    = +""
      @location = nil
      @request_format = :html
      @accepts_any_format = false
      @content_type = "text/html; charset=utf-8"
      @headers = {}
      @performed = false
      # Set unconditionally: under AOT an ivar never seen assigned has no type
      # to infer, and the readers above are reachable on every controller.
      # 0 = "no max-age stated", which is also what a response without the
      # header means.
      @cache_control_max_age = 0
      @cache_control_public = false
      # Unconditional for the same AOT type-inference reason as the
      # cache-control pair above.
      @action_name = nil
    end

    # true once render/redirect_to/head has produced a response. Two gates read
    # it: the action dispatch skips the action after a filter that responded
    # (the halting rule), and `send_action` skips the implicit 204 once anything
    # — filter or action — has answered.
    #
    # @return [Boolean] true once a response has been produced
    def performed?
      @performed
    end

    # ---- before_action filter chain --------------------------------------
    # Shaped by spinel's limits: no callback chain, no ancestor propagation
    # of registration (the `inherited` hook is never called). The
    # module-level constant Array below is the registry; a class ivar is not
    # carried. Per-method contracts sit on `before_action` and
    # `run_before_filters`.
    BEFORE_FILTERS = []

    # register before-filters for the receiving controller class. Each name is a
    # Symbol method the chain dispatches with `send` at run time — the method
    # may live on the controller or a parent, and private is fine (`send`
    # reaches both). Registration records the owner class: a filter runs only on
    # instances of the class that registered it — the `inherited` hook is never
    # called, so the registration itself does not propagate to subclasses
    # (declare it there again, or share the method on a parent).
    #
    # @param names [Array[Symbol]] filter method names, run in
    #   registration order
    # @param only [Symbol, Array[Symbol], nil] run the filter only on
    #   these actions; conditional filters need the action context
    #   (`action_name=`) at run time and raise without it
    # @param except [Symbol, Array[Symbol], nil] skip the filter on
    #   these actions — same context requirement as `only:`
    # @raise [ArgumentError] on a non-Symbol name — a String would
    #   miss every method at request time, far from the typo
    # @example
    #   before_action :authenticate_user!
    #   before_action :mark_create, only: :create
    #   before_action :mark_all, except: [:show, :index]
    def self.before_action(*names, only: nil, except: nil)
      names.each do |name|
        raise ArgumentError, "before_action expects Symbols, got #{name}" unless name.is_a?(Symbol)
      end
      only_list   = only.nil?   ? [] : (only.is_a?(Array)   ? only   : [only])
      except_list = except.nil? ? [] : (except.is_a?(Array) ? except : [except])
      BEFORE_FILTERS << [self.name, names, only_list, except_list]
    end

    # run this controller's registered before-filters in registration order,
    # each gated by its `only:`/`except:` lists. The chain stops at the first
    # filter that has produced a response: a filter that renders/redirects/heads
    # skips the remaining filters and, at the call site, the action body.
    #
    # @return [void]
    # @raise [RuntimeError] a filter carrying `only:`/`except:` ran
    #   without the action context — set `self.action_name =` before
    #   calling; silently applying the filter to every action (or
    #   none) would hide a mis-configured guard
    # @example
    #   self.action_name = :create
    #   run_before_filters
    def run_before_filters
      BEFORE_FILTERS.each do |entry|
        next unless entry[0] == self.class.name
        entry[1].each do |name|
          next unless filter_applies?(entry[2], entry[3])
          send(name)
          return if performed?
        end
      end
    end

    # dispatch one matched action: set the action context, run the controller's
    # registered before-filters, then hand off to `send_action`.
    #
    # A filter that responds (render/redirect/head) marks the response
    # performed and the action is skipped — the halting rule. A name with
    # no method raises rather than answering a silent empty 200.
    # Subclasses override only to wrap this preamble (e.g. a locale
    # around-block); an override that replaces the dispatch entirely
    # must call `send_action` (not bare `send`) in its place or its
    # actions lose the implicit 204.
    #
    # @param action_name [Symbol] the action to dispatch
    # @return [void]
    # @raise [NoMethodError] no method carries the action's name
    # @example
    #   process_action(:show)
    def process_action(action_name)
      self.action_name = action_name
      run_before_filters
      send_action(action_name) unless performed?
    end

    # call the action by name, then answer 204 No Content when it produced no
    # response. The implicit-render half of dispatch: an action with nothing to
    # return still owes the caller a definite status, and the constructor's
    # empty 200 says "success with a body" while carrying neither — a failure
    # class that slips past any `:success` assertion. 204 is the definite answer
    # for "done, nothing to return" (DELETE acknowledgements and other
    # fire-and-forget writes are the common shape).
    #
    # `performed?` is the gate on purpose: a response already produced —
    # by the action body, or by a before-filter that halted the chain —
    # is the answer and is never overwritten (`head` would clobber a
    # rendered status and body). Wrapping callers (a preamble that runs
    # the filters itself) call this rather than `send` so their actions
    # keep the implicit render.
    #
    # @param action_name [Symbol] the action to call
    # @return [void]
    # @raise [NoMethodError] no method carries the action's name
    # @example
    #   send_action(:destroy)
    def send_action(action_name)
      send(action_name)
      default_render unless performed?
    end

    # sets @body, @status, and optionally @content_type / @location. The
    # `location:` kwarg sets @location so the response ships a Location header
    # alongside the rendered body — the
    # `render :show, status: :created, location: @article` idiom for POST 201
    # responses. Distinct from redirect_to (which uses a 3xx status); main.rb
    # dispatches on status, not on @location nil-ness.
    #
    # The `json:` keyword is the payload form: `render json: value`
    # encodes the value with ActionController::JsonRender and answers
    # JSON_CONTENT_TYPE unless `content_type:` names another. It takes a
    # payload, not encoded text — `render json: "hi"` answers `"hi"`
    # with quotes; already-encoded JSON belongs in the positional body,
    # which is what `render(JsonRender.encode(v), content_type: ...)`
    # keeps producing. Exactly one of the two bodies must be given: a
    # caller that passes neither forgot the argument, and a caller that
    # passes both left two answerable meanings, so both raise instead
    # of guessing. `json:` carries nil fine — it encodes to `null`, and
    # the JSON_NOT_GIVEN sentinel is what keeps that apart from an
    # omitted keyword.
    #
    # @param body [String, nil] the pre-rendered response body
    # @param status [Symbol, Integer] symbolic status (resolved through Snails::Utils::SYMBOL_TO_STATUS_CODE) or an integer code
    # @param content_type [String, nil] overrides the response content type
    # @param location [String, nil] sets @location for the Location header
    # @param json [Object, nil] the payload to encode as the JSON response body
    # @return [void]
    # @raise [ArgumentError] when neither or both of body/json: is given
    # @example
    #   render("denied", status: :unauthorized)
    # @example
    #   render(json: { error: "not found" }, status: 404)
    # @example
    #   render(json: nil)
    def render(body = nil, status: :ok, content_type: nil, location: nil, json: JSON_NOT_GIVEN)
      if JSON_NOT_GIVEN.equal?(json)
        # json: omitted — the positional body carries the response.
        raise ArgumentError, "render takes a body or json:" if body.nil?
        @body = body
      else
        # json: given — nil is a payload like any other (it encodes to null).
        raise ArgumentError, "render takes a body or json:, not both" unless body.nil?
        @body = ActionController::JsonRender.encode(json)
        content_type = JSON_CONTENT_TYPE if content_type.nil?
      end
      @status = resolve_status(status)
      @performed = true
      @content_type = content_type unless content_type.nil?
      @location = location unless location.nil?
    end

    # sets location and status. The default is 302 (Found); a PATCH/DELETE
    # response that must not be replayed passes `status: :see_other` (303).
    #
    # @param status [Symbol, Integer] symbolic status (resolved through Snails::Utils::SYMBOL_TO_STATUS_CODE) or an integer code
    # @return [void]
    def redirect_to(path, status: :found)
      @location = path
      @status   = resolve_status(status)
      @performed = true
    end

    # empty body, status only. `content_type` is optional: omit it and the
    # default text/html stands, while an explicit value costs nothing — clients
    # may still parse the header.
    #
    # `location:` records the resource a 201 created
    # (`head :created, location: ...`). It is not a redirect — that is a
    # 3xx status — so a location beside a 201 is only a stated URL.
    #
    # @param status [Symbol, Integer] symbolic status (resolved through Snails::Utils::SYMBOL_TO_STATUS_CODE) or an integer code
    # @param content_type [String, nil] overrides the response content type
    # @param location [String, nil] sets the Location header value
    # @return [void]
    def head(status, content_type: nil, location: nil)
      @location = location unless location.nil?
      @status = resolve_status(status)
      @body   = +""
      @performed = true
      @content_type = content_type unless content_type.nil?
    end

    # the surface app actions write headers through
    # (`response.headers["Expires"] = ...`). The controller is its own buffered
    # response, so `response` returns self and `headers` the extra-header hash.
    # Those headers are buffered but not sent yet; they tune caching, not
    # content.
    #
    # @return [API] the controller itself
    def response
      self
    end

    # ---- conditional GET: always stale ------------------------------
    #
    # `fresh_when` / `stale?` answer "stale, render it". Neither half of the
    # 304 comparison exists here: this controller has no request object (only
    # `@request_format`), so there is nothing to read `If-None-Match` /
    # `If-Modified-Since` from, and the extra-header hash above is buffered
    # but never sent, so there is nothing to write validators to. Always
    # rendering is semantically correct for every request — it just never
    # earns the 304, so the cost is bandwidth, not behavior.
    #
    # One shape per method (`fresh_when(subject)`, `stale?(etag:)`), each
    # added when a call site asks, rather than one method with a union
    # parameter the compiler cannot narrow.

    # the conditional-GET hook: it takes the subject a caller would send
    # validators for and stores nothing, because this runtime never answers a
    # 304 and always renders.
    #
    # The body is empty, not a bare `nil`: a `nil`-only body gives the
    # compiler an optional type with nothing to infer its parameter from,
    # where an empty body is a plain `void`.
    #
    # @param subject [Object] the record the validators describe — named
    #   `subject` rather than `record` because a lowering passes the
    #   controller as an implicit first argument called `record`, and a
    #   same-named parameter of our own collides with it
    # @return [void]
    def fresh_when(subject)
    end

    # always true: this controller never answers a 304, so the validator
    # argument is accepted and ignored.
    #
    # @param etag [String, nil] accepted for the call shape; never read
    # @return [Boolean] always true
    def stale?(etag: nil)
      true
    end

    # the Cache-Control writer: it stores the two facts and writes no header
    # (see `headers`).
    #
    # Seconds, not a Duration: the lowering unwraps `1.year` at the call
    # site, so the signature stays Integer. `stale_while_revalidate: 0`
    # means "not stated", which keeps it Integer rather than nullable; the
    # value itself is not stored.
    #
    # @param seconds [Integer] the max-age to store, in seconds
    # @param public [Boolean] store the response as publicly cacheable
    # @param stale_while_revalidate [Integer] seconds, or 0 for "not stated"
    # @return [void]
    def expires_in(seconds, public: false, stale_while_revalidate: 0)
      @cache_control_max_age = seconds
      @cache_control_public = public
    end

    def headers
      @headers
    end

    # a binary response body, buffered like `render`. `disposition` is accepted
    # but not written out: the Content-Disposition header stays buffered like
    # the ones in `headers` until the response ships.
    #
    # @param disposition [String] accepted for the Content-Disposition
    #   header, which is not written yet
    # @return [void]
    def send_data(data, type: "application/octet-stream", disposition: "attachment")
      @body = data
      @content_type = type
      @performed = true
    end

    # a status to its HTTP integer code. Both forms are accepted: a Symbol
    # resolves through Snails::Utils::SYMBOL_TO_STATUS_CODE, and an Integer is
    # used as given within 100..599. Anything else raises — a value the caller
    # mistyped (`status: 2000`, `status: :okay`) must not fall through to the
    # 200 default and read as a normal success. The message names both accepted
    # forms so the caller can fix the line from the raise.
    #
    # @param s [Symbol, Integer] the symbolic status name or the integer code
    # @return [Integer] the HTTP status code
    # @raise [RuntimeError] the value is neither a known symbol nor an integer in 100..599
    def resolve_status(s)
      if s.is_a?(Integer)
        if s < 100 || s > 599
          raise "Invalid HTTP status: #{s} — pass an integer in 100..599 or a symbol like :ok"
        end
        return s
      end
      if Snails::Utils::SYMBOL_TO_STATUS_CODE.key?(s)
        return Snails::Utils::SYMBOL_TO_STATUS_CODE.fetch(s, 200)
      end
      raise "Invalid HTTP status: #{s} — pass a symbol like :ok or an integer in 100..599"
    end

    private

    # The implicit response for an action that produced none — 204 No
    # Content, status only. Private on purpose: it runs inside
    # `send_action`, and an app changes the answer by rendering in the
    # action, not by replacing this default.
    def default_render
      head(:no_content)
    end

    # only/except gate — true when the current action matches. `only:`
    # limits the filter to the listed actions; `except:` excludes
    # them. Without an action context, a conditional filter raises (the
    # loud contract — a silent skip would hide a mis-configured guard).
    # Internal to run_before_filters — not part of the public surface.
    def filter_applies?(only_list, except_list)
      if @action_name.nil?
        return true if only_list.empty? && except_list.empty?
        raise "only:/except: filter needs an action context (set action_name before run_before_filters)"
      end
      return false unless only_list.empty? || only_list.include?(@action_name)
      return false if except_list.include?(@action_name)
      true
    end
  end
end
