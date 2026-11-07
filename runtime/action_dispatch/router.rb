# Path router: matches (method, path) against a typed route table and resolves
# to (controller, action, path params).
#
# Route rows are typed `Route` instances rather than `Hash[Symbol, untyped]`,
# so each per-field type is statically known. Path captures land as
# `Hash[String, String]`: URL segments are always strings.

module ActionDispatch
  module Router
    # One entry in the route table: a typed class so each per-field type is
    # statically known. `verb` rather than `method`, which Ruby's `Object`
    # already answers.
    #
    # `controller` holds the class, not a symbol: the dispatcher calls
    # `matched.controller.new`, and a symbol would need a second mapping back to
    # the class that drifts from the table.
    #
    # Positional `initialize`: keywords do not convert symmetrically between
    # definition and call site, and this is an internal class.
    class Route
      attr_reader :verb, :pattern, :controller, :action, :req_format, :int_params,
                  :pattern_parts

      # `req_format` — the route-forced response format (a route
      # declared `get "/rss" => "home#index", :format => "rss"`), nil
      # for the common infer-from-path case. Named `req_format` (not
      # `format`) so targets whose stdlibs claim `format` never collide.
      #
      # `int_params` — space-joined names of path params constrained to
      # digit-only segments (Roda's `Integer` matcher, a `constraints:`
      # digit class), e.g. `"id"` or `"article_id id"`; the empty
      # string for the unconstrained common case. A candidate segment
      # that isn't all digits makes the route a non-match, so
      # `/articles/12abc` falls through to 404 instead of binding
      # `id = "12abc"`.
      # @param verb [String] the HTTP verb ("GET", "POST", ...)
      # @param pattern [String] the path pattern, e.g. "/devices/:id"
      # @param controller [Class] the controller class dispatched to
      # @param action [Symbol] the action dispatched
      # @param req_format [Symbol, nil] route-forced response format
      # @param int_params [String] space-joined digit-constrained param names
      def initialize(verb, pattern, controller, action, req_format = nil, int_params = +"")
        @verb        = verb
        @pattern     = pattern
        @controller  = controller
        @action      = action
        @req_format  = req_format
        @int_params  = int_params
        # Split ONCE, at table-construction time: the table is built at boot,
        # while `Router.match` is a linear scan that would otherwise split every
        # candidate pattern on every request.
        @pattern_parts = pattern.split("/")
      end

    end

    # The result of a successful `Router.match` call: the resolved controller
    # class, action symbol, and captured path parameters. Positional
    # initialize, same rationale as Route.
    class MatchResult
      attr_reader :controller, :action, :path_params, :req_format

      def initialize(controller, action, path_params, req_format = nil)
        @controller  = controller
        @action      = action
        @path_params = path_params
        @req_format  = req_format
      end
    end

    # `match(method, path, table)` — the routing entry: the first row whose
    # verb and pattern match the request.
    #
    # @param method [String] the request verb
    # @param path [String] the request path
    # @param table [Array] the route table (`Snails::RouteTable.table`)
    # @return [MatchResult, nil] the match, or nil when no row matches
    def self.match(method, path, table)
      # A last-segment `(.:format)` suffix names the response format; it is not
      # part of the path. `POST /rooms/3/messages.turbo_stream` matches the same
      # route as `/rooms/3/messages` and sets `params["format"]`.
      #
      # The stripped form is tried first. A dynamic segment never contains a
      # dot, so peeling the format before binding is what keeps `:id` from
      # swallowing the extension (`6.turbo_stream`). A collection path's literal
      # last segment cannot swallow anything, which is why only member routes
      # showed the mistake.
      #
      # The literal path is the fallback, so a route that genuinely contains a
      # dot (`/manifest.json`) still matches. Only registered extensions strip,
      # so `/robots.txt` and `/domains/example.com` stay untouched. An app
      # declaring both `/manifest` and `/manifest.json` gets the former for the
      # dotted request, where declaration order would otherwise decide.
      #
      # One split of the whole path: the extension must be in the last segment,
      # and `include?("/")` checks that directly.
      dotted = path.split(".")
      if dotted.length >= 2
        ext = dotted[dotted.length - 1]
        if !ext.include?("/") && format_extension(ext)
          # Trimming from the FULL path (rather than rewriting the segment
          # array and re-joining) avoids an array index assignment, a shape
          # the lowering does not carry.
          stripped = match_path(method, path[0, path.length - ext.length - 1].to_s, table, ext)
          return stripped unless stripped.nil?
        end
      end
      match_path(method, path, table, +"")
    end

    # Is `ext` one of the registered format extensions? A closed, published set
    # copied whole: a dispatcher that sniffs only `.json` leaves
    # `.turbo_stream` matching no route.
    #
    # A space-delimited String scanned by split-and-compare lowers cleanly,
    # unlike a constant Hash (loosely typed values) or a substring test (needs a
    # concatenation). No `?` suffix: the lowering appends a loop suffix to a
    # while-loop method's own name.
    def self.format_extension(ext)
      known = "html text js css ics csv vcf vtt png jpeg jpg gif bmp tiff svg webp mpeg mp3 mp4 ogg webm otf ttf woff woff2 pdf zip gzip xml rss atom yaml json".split(" ")
      i = 0
      while i < known.length
        return true if known[i] == ext
        i += 1
      end
      false
    end

    # One scan of the table for a literal path. `format` is the extension the
    # REQUEST carried ("" when it carried none); it reaches the action as
    # `params["format"]` — where the `(.:format)` segment lands.
    def self.match_path(method, path, table, format)
      method_upcase = method.to_s.upcase
      path_parts = path.split("/")
      i = 0
      while i < table.length
        route = table[i]
        if route.verb.to_s == method_upcase
          params = match_parts(route.pattern_parts, path_parts, route.int_params, format)
          unless params.nil?
            return ActionDispatch::Router::MatchResult.new(route.controller, route.action, params, route.req_format)
          end
        end
        i += 1
      end
      nil
    end

    # Match a path against a pattern containing `:name` segments. Returns
    # `Hash[String, String]` captures, or nil on no match. No regex — segment by
    # segment; captures are always string-to-string.
    #
    # `int_params` is the route's space-joined digit-only constraint list: a
    # constrained segment that is not all digits makes the pattern a non-match.
    # The check runs on the raw segment before capture, so no caller reads a nil
    # hash entry.
    def self.match_pattern(pattern, path, int_params = +"")
      match_parts(pattern.split("/"), path.split("/"), int_params)
    end

    # The segment loop over already-split parts. `Router.match` feeds it the
    # route's precomputed `pattern_parts` and the request path split once, so a
    # table walk allocates nothing per candidate.
    #
    # `format` is captured here beside the `:name` segments rather than being
    # inserted by the caller: this is the only place the hash is a fresh local
    # of known shape.
    #
    # A `*name` GLOB segment (`*filename`) must be last and takes every
    # remaining segment, slash-joined; every other route needs an exact count.
    def self.match_parts(pattern_parts, path_parts, int_params = +"", format = +"")
      # The tail segment is bound to a local before it is asked anything, like
      # `pp`/`ap` below.
      last = pattern_parts.length - 1
      globbed = false
      if last >= 0
        tail = pattern_parts[last]
        globbed = tail.start_with?("*")
      end
      if globbed
        return nil if path_parts.length < pattern_parts.length
      elsif pattern_parts.length != path_parts.length
        return nil
      end
      params = {}
      params["format"] = format unless format.empty?
      i = 0
      while i < pattern_parts.length
        pp = pattern_parts[i]
        ap = path_parts[i]
        if pp.start_with?("*")
          params[pp[1..]] = glob_rest(path_parts, i)
        elsif pp.start_with?(":")
          name = pp[1..]
          # Route the segment through `to_s` before `digits_only`: a bare
          # array-index local is typed loosely, and `to_s` hands the check a
          # definite String.
          seg = ap.to_s
          if int_constrained(int_params, name) && !digits_only(seg)
            return nil
          end
          params[name] = ap
        elsif pp != ap
          # A literal PREFIX before the `:name` in the same segment
          # (`/~:username`, `/@:username`). The prefix is literal and the rest
          # of the segment binds to the param. Checked only on a mismatch, and
          # behind `include?`, so a plain literal segment costs what it did.
          return nil unless pp.include?(":")
          plen = param_prefix_length(pp)
          return nil if plen <= 0 || ap.length <= plen
          return nil unless ap.start_with?(pp[0, plen].to_s)
          params[pp[plen + 1, pp.length].to_s] = ap[plen, ap.length].to_s
        end
        i += 1
      end
      params
    end

    # The path from segment `from` on, slash-joined: a `*glob`'s value. Its own
    # method rather than a loop inside `match_parts` because the lowering turns
    # one `while` per method into a recursive loop helper; a second, nested one
    # is not a shape it takes.
    def self.glob_rest(path_parts, from)
      rest = []
      j = from
      while j < path_parts.length
        seg = path_parts[j]
        rest << seg
        j += 1
      end
      rest.join("/")
    end

    # Where the `:` of a prefixed param segment (`~:username`) sits — the
    # prefix's length; -1 when the segment has none. Its own method for the same
    # one-`while`-per-method reason as `glob_rest`.
    def self.param_prefix_length(segment)
      i = 0
      while i < segment.length
        return i if segment[i, 1].to_s == ":"
        i += 1
      end
      -1
    end

    # Is `name` one of the route's digit-constrained params? `int_params` is the
    # space-joined constraint list carried on `Route`; the empty string means
    # the route constrains nothing. Membership by split + `==` scan (no
    # `Array#include?`, no `Hash` read) — the membership test that lowers
    # cleanly.
    def self.int_constrained(int_params, name)
      return false if int_params.empty?
      parts = int_params.split(" ")
      i = 0
      while i < parts.length
        return true if parts[i] == name
        i += 1
      end
      false
    end

    # All-digits check for constrained segments. No regex (the router has to
    # compile as written) and no `to_i` round-trip: a round-trip would reject
    # the leading zeros a digit constraint accepts (`/articles/007` is id 7,
    # not a 404). The digit test is an explicit `String#==` fan-out rather than
    # `"0123456789".include?(c)`, a form the compiler handles.
    def self.digits_only(s)
      return false if s.empty?
      i = 0
      while i < s.length
        c = s[i, 1].to_s
        if c != "0" && c != "1" && c != "2" && c != "3" && c != "4" &&
           c != "5" && c != "6" && c != "7" && c != "8" && c != "9"
          return false
        end
        i += 1
      end
      true
    end

    # Private on purpose: `match` is the entry; these helpers are free to
    # change without notice.
    private_class_method :format_extension, :match_path, :match_pattern, :match_parts
    private_class_method :glob_rest, :param_prefix_length, :int_constrained, :digits_only
  end
end
