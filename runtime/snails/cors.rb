# CORS at the request boundary: an app-owned policy and the protocol
# evaluation the dispatcher runs for every request. The policy is a value —
# which origins, methods, headers, credentials, and cache lifetime a browser
# may use. The algorithm is the Fetch preflight and response-header rules.
#
# The app sets `Snails.cors` in `config/environment.rb`; the default nil
# means no CORS. A preflight is answered before routing and auth, and the
# actual-response headers are placed on the response before the app runs so
# a 404, 400, 401, or 500 carries them too.
module Snails
  # the app's CORS policy, or nil when the app sets none.
  #
  # @return [Snails::Cors::Policy, nil] the configured policy
  def self.cors
    @cors
  end

  # set the app's CORS policy. An app calls this from `config/environment.rb`
  # because the allowed origin differs by environment.
  #
  # @param policy [Snails::Cors::Policy, nil] the policy, or nil to disable
  # @return [Snails::Cors::Policy, nil] the assigned policy
  # @raise [ArgumentError] the value is neither a policy nor nil
  def self.cors=(policy)
    if !policy.nil? && !policy.is_a?(Snails::Cors::Policy)
      raise ArgumentError, "Snails.cors expects a Snails::Cors::Policy or nil"
    end
    @cors = policy
  end

  module Cors
    # The browser-facing allow-list. Origins are exact strings (scheme, host,
    # and port) or `"*"`; allowed_methods are HTTP verbs; allowed_headers
    # are names a preflight may ask for, or `["*"]` to echo the list.
    #
    # @example
    #   Snails.cors = Snails::Cors::Policy.new(
    #     ["https://app.example.com"],
    #     ["GET", "POST"],
    #     ["Content-Type"],
    #     true,
    #     600
    #   )
    class Policy
      # the exact origins the policy allows, or `["*"]`.
      attr_reader :origins
      # the uppercase methods a preflight may ask for.
      attr_reader :allowed_methods
      # the allowed request header names; `["*"]` allows any.
      attr_reader :allowed_headers
      # whether the browser may send credentials.
      attr_reader :allow_credentials
      # the preflight cache lifetime; 0 omits the header.
      attr_reader :max_age
      # response header names the browser may read; empty omits the header.
      attr_reader :expose

      # @param origins [Array<String>] exact origins, or `["*"]`
      # @param allowed_methods [Array<String>] HTTP methods
      # @param allowed_headers [Array<String>] allowed request header names;
      #   `["*"]` allows any
      # @param allow_credentials [Boolean] allow credentials
      # @param max_age [Integer] preflight cache seconds; 0 omits the header
      # @param expose [Array<String>] response headers the browser may read
      # @return [void]
      # @raise [ArgumentError] an empty list, a malformed member, `"*"` mixed
      #   with named origins, or `"*"` with credentials
      def initialize(origins, allowed_methods, allowed_headers = [], allow_credentials = false, max_age = 0, expose = [])
        @origins = names(origins, "origins")
        @allowed_methods = names(allowed_methods, "methods")
        @allowed_headers = names(allowed_headers, "headers")
        @allow_credentials = boolean_value(allow_credentials, "credentials")
        @max_age = integer_value(max_age, "max_age")
        @expose = names(expose, "expose")
        raise ArgumentError, "CORS origins must not be empty" if @origins.empty?
        raise ArgumentError, "CORS methods must not be empty" if @allowed_methods.empty?
        if @origins.include?("*")
          if @origins.length > 1
            raise ArgumentError, 'CORS origins cannot mix "*" with named origins'
          end
          if @allow_credentials
            raise ArgumentError, 'CORS "*" cannot be combined with credentials'
          end
        end
        i = 0
        while i < @allowed_methods.length
          @allowed_methods[i] = @allowed_methods[i].upcase
          i += 1
        end
      end

      def names(values, label)
        if !values.is_a?(Array)
          raise ArgumentError, "CORS #{label} must be an Array of Strings"
        end
        out = []
        i = 0
        while i < values.length
          value = values[i]
          if !value.is_a?(String) || value.empty?
            raise ArgumentError, "CORS #{label} must contain non-empty Strings"
          end
          out.push(value)
          i += 1
        end
        out
      end

      def boolean_value(value, label)
        return true if value == true
        return false if value == false
        raise ArgumentError, "CORS #{label} must be true or false"
      end

      def integer_value(value, label)
        if !value.is_a?(Integer) || value < 0
          raise ArgumentError, "CORS #{label} must be a non-negative Integer"
        end
        value
      end

      private :names, :boolean_value, :integer_value
    end

    # answer a preflight when the request is one. A request is a preflight
    # when it is `OPTIONS`, carries an `Origin`, and names a method in
    # `Access-Control-Request-Method`. A denied request still gets a 204 with
    # no CORS headers, so the browser blocks without learning the policy.
    #
    # @param req [Tep::Request] the parsed request
    # @param res [Tep::Response] the response to fill
    # @param policy [Snails::Cors::Policy, nil] the policy; defaults to
    #   `Snails.cors`
    # @return [Boolean] true when the request was answered as a preflight
    def self.preflight(req, res, policy = Snails.cors)
      return false if policy.nil?
      return false unless req.verb == "OPTIONS"
      origin = req.req_headers["origin"].to_s
      requested_method = req.req_headers["access-control-request-method"].to_s
      return false if origin.empty? || requested_method.empty?
      res.status = 204
      res.body = +""
      add_vary(res, "Origin")
      add_vary(res, "Access-Control-Request-Method")
      add_vary(res, "Access-Control-Request-Headers")
      return true unless origin_allowed?(policy, origin)
      return true unless verb_allowed?(policy, requested_method)
      requested = req.req_headers["access-control-request-headers"].to_s
      return true unless request_headers_allowed?(policy, requested)
      res.headers["Access-Control-Allow-Origin"] = allow_origin(policy, origin)
      res.headers["Access-Control-Allow-Methods"] = policy.allowed_methods.join(", ")
      if policy.allowed_headers.include?("*")
        res.headers["Access-Control-Allow-Headers"] = requested unless requested.empty?
      else
        res.headers["Access-Control-Allow-Headers"] = policy.allowed_headers.join(", ") unless policy.allowed_headers.empty?
      end
      res.headers["Access-Control-Allow-Credentials"] = "true" if policy.allow_credentials
      res.headers["Access-Control-Max-Age"] = policy.max_age.to_s if policy.max_age > 0
      true
    end

    # place the actual-response CORS headers. It runs before the app so a
    # framework-generated 404, 400, or 401 carries them, and again after the
    # app so an app-set `Vary` is merged rather than dropped. A denied origin
    # gets `Vary: Origin` and no allow header.
    #
    # @param req [Tep::Request] the parsed request
    # @param res [Tep::Response] the response to fill
    # @param policy [Snails::Cors::Policy, nil] the policy; defaults to
    #   `Snails.cors`
    # @return [void]
    def self.apply(req, res, policy = Snails.cors)
      return if policy.nil?
      origin = req.req_headers["origin"].to_s
      return if origin.empty?
      add_vary(res, "Origin")
      return unless origin_allowed?(policy, origin)
      res.headers["Access-Control-Allow-Origin"] = allow_origin(policy, origin)
      res.headers["Access-Control-Allow-Credentials"] = "true" if policy.allow_credentials
      unless policy.expose.empty?
        res.headers["Access-Control-Expose-Headers"] = policy.expose.join(", ")
      end
    end

    def self.origin_allowed?(policy, origin)
      origins = policy.origins
      i = 0
      while i < origins.length
        return true if origins[i] == "*" || origins[i] == origin
        i += 1
      end
      false
    end

    def self.verb_allowed?(policy, verb)
      wanted = verb.upcase
      verbs = policy.allowed_methods
      i = 0
      while i < verbs.length
        return true if verbs[i] == wanted
        i += 1
      end
      false
    end

    def self.request_headers_allowed?(policy, requested)
      return true if requested.empty?
      headers = policy.allowed_headers
      return true if headers.include?("*")
      parts = requested.split(",")
      i = 0
      while i < parts.length
        name = parts[i].strip
        allowed = false
        j = 0
        while j < headers.length
          if headers[j].downcase == name.downcase
            allowed = true
          end
          j += 1
        end
        return false unless allowed
        i += 1
      end
      true
    end

    def self.allow_origin(policy, origin)
      origins = policy.origins
      i = 0
      while i < origins.length
        return "*" if origins[i] == "*"
        i += 1
      end
      origin
    end

    def self.add_vary(res, value)
      current = res.headers["Vary"].to_s
      if current.empty?
        res.headers["Vary"] = value
        return
      end
      parts = current.split(",")
      i = 0
      while i < parts.length
        return if parts[i].strip == value
        i += 1
      end
      res.headers["Vary"] = current + ", " + value
    end

    private_class_method :origin_allowed?, :verb_allowed?, :request_headers_allowed?
    private_class_method :allow_origin, :add_vary
  end
end
