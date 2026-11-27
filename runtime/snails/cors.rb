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
  # @raise [TypeError] the value is neither a policy nor nil
  def self.cors=(policy)
    if !policy.nil? && !policy.is_a?(Snails::Cors::Policy)
      raise TypeError, "Snails.cors expects a Snails::Cors::Policy or nil"
    end
    @cors = policy
  end

  module Cors
    # The browser-facing allow-list. Origins are exact `scheme://host[:port]`
    # strings, `"*"`, or `"null"`; a trailing slash or path is not an origin
    # and does not match. allowed_methods are HTTP verbs; allowed_headers are
    # names a preflight may ask for, or `["*"]` to echo the list.
    #
    # @example
    #   Snails.cors = Snails::Cors::Policy.new(
    #     origins: ["https://app.example.com"],
    #     allowed_methods: ["GET", "POST"],
    #     allowed_headers: ["Content-Type"],
    #     allow_credentials: true,
    #     max_age: 600,
    #     exposed_headers: ["X-Total-Count"]
    #   )
    class Policy
      # the exact origins the policy allows, `["*"]`, or `["null"]`.
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
      attr_reader :exposed_headers

      # @param origins [Array<String>] exact origins, `["*"]`, or `["null"]`
      # @param allowed_methods [Array<String>] HTTP methods
      # @param allowed_headers [Array<String>] allowed request header names;
      #   `["*"]` allows any
      # @param allow_credentials [Boolean] allow credentials
      # @param max_age [Integer] preflight cache seconds; 0 omits the header
      # @param exposed_headers [Array<String>] response headers the browser may
      #   read
      # @return [void]
      # @raise [ArgumentError] empty origins or allowed_methods, a malformed
      #   member, `"*"` mixed with named origins, or `"*"` with credentials
      def initialize(origins:, allowed_methods:, allowed_headers: [], allow_credentials: false, max_age: 0, exposed_headers: [])
        @origins = origin_values(origins)
        @allowed_methods = token_values(allowed_methods, "methods")
        @allowed_headers = token_values(allowed_headers, "headers")
        @allow_credentials = boolean_value(allow_credentials, "credentials")
        @max_age = integer_value(max_age, "max_age")
        @exposed_headers = token_values(exposed_headers, "exposed_headers")
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

      # whether the policy allows the origin. Matching is exact: a trailing
      # slash, a path, or different casing does not match. A missing or empty
      # origin is never allowed, even under `"*"`, because an Origin check
      # must not treat "no origin" as an allowed origin.
      #
      # @param origin [String, nil] the Origin header value
      # @return [Boolean] true when the policy lists the origin or `"*"`
      # @raise [ArgumentError] the value is neither a String nor nil
      # @example
      #   policy.origin_allowed?("https://app.example.com") # => true
      def origin_allowed?(origin)
        if !origin.nil? && !origin.is_a?(String)
          raise ArgumentError, "origin_allowed? expects a String or nil"
        end
        return false if origin.nil? || origin.empty?
        i = 0
        while i < @origins.length
          return true if @origins[i] == "*" || @origins[i] == origin
          i += 1
        end
        false
      end

      def origin_values(values)
        if !values.is_a?(Array)
          raise ArgumentError, "CORS origins must be an Array of Strings"
        end
        out = []
        i = 0
        while i < values.length
          out.push(origin_value(values[i]))
          i += 1
        end
        out
      end

      def origin_value(value)
        if value == "*" || value == "null"
          return value
        end
        if !value.is_a?(String) || value.empty?
          raise ArgumentError, "CORS origins must contain non-empty Strings"
        end
        if value.start_with?("http://")
          rest = value[7, value.length - 7]
        elsif value.start_with?("https://")
          rest = value[8, value.length - 8]
        else
          raise ArgumentError, "CORS origins must start with http:// or https://"
        end
        if rest.empty?
          raise ArgumentError, "CORS origin needs a host"
        end
        i = 0
        while i < rest.bytesize
          byte = rest.getbyte(i)
          if byte <= 0x20 || byte >= 0x7F || byte == 0x3B || byte == 0x2C ||
             byte == 0x2F || byte == 0x3F || byte == 0x23
            raise ArgumentError, "CORS origin contains an invalid character"
          end
          i += 1
        end
        validate_origin_port(rest)
        value
      end

      def validate_origin_port(rest)
        if rest.start_with?("[")
          return
        end
        last_colon = -1
        i = 0
        while i < rest.bytesize
          if rest.getbyte(i) == 0x3A
            last_colon = i
          end
          i += 1
        end
        return if last_colon < 0
        host = rest[0, last_colon]
        port = rest[last_colon + 1, rest.length - last_colon - 1]
        if host.empty? || port.empty?
          raise ArgumentError, "CORS origin needs a host and a numeric port"
        end
        if host.include?(":")
          raise ArgumentError, "CORS origin host must not contain a colon"
        end
        i = 0
        while i < port.length
          byte = port.getbyte(i)
          if byte < 0x30 || byte > 0x39
            raise ArgumentError, "CORS origin port must be numeric"
          end
          i += 1
        end
        number = port.to_i
        if number < 1 || number > 65535
          raise ArgumentError, "CORS origin port must be in 1..65535"
        end
      end

      def token_values(values, label)
        if !values.is_a?(Array)
          raise ArgumentError, "CORS #{label} must be an Array of Strings"
        end
        out = []
        i = 0
        while i < values.length
          value = values[i]
          if !token_value?(value)
            raise ArgumentError, "CORS #{label} must contain HTTP tokens"
          end
          out.push(value)
          i += 1
        end
        out
      end

      def token_value?(value)
        if !value.is_a?(String) || value.empty?
          return false
        end
        i = 0
        while i < value.bytesize
          byte = value.getbyte(i)
          return false if byte < 0x21 || byte > 0x7E
          return false if byte == 0x28 || byte == 0x29 || byte == 0x3C || byte == 0x3E
          return false if byte == 0x40 || byte == 0x2C || byte == 0x3B || byte == 0x3A
          return false if byte == 0x5C || byte == 0x22 || byte == 0x2F || byte == 0x5B
          return false if byte == 0x5D || byte == 0x3F || byte == 0x3D || byte == 0x7B
          return false if byte == 0x7D
          i += 1
        end
        true
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

      private :origin_values, :origin_value, :validate_origin_port
      private :token_values, :token_value?, :boolean_value, :integer_value
    end

    # answer a preflight when the request is one. A request is a preflight
    # when it is `OPTIONS`, carries an `Origin`, and names a method in
    # `Access-Control-Request-Method`. A denied request still gets a 204 with
    # no allow headers, so the browser blocks without learning the policy.
    #
    # @api internal
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
      return true unless policy.origin_allowed?(origin)
      return true unless verb_allowed?(policy, requested_method)
      requested = req.req_headers["access-control-request-headers"].to_s
      return true unless request_headers_allowed?(policy, requested)
      res.headers["Access-Control-Allow-Origin"] = allow_origin(policy, origin)
      res.headers["Access-Control-Allow-Methods"] = policy.allowed_methods.join(", ")
      if policy.allowed_headers.include?("*")
        names = requested_header_names(requested)
        res.headers["Access-Control-Allow-Headers"] = names.join(", ") unless names.nil? || names.empty?
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
    # @api internal
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
      return unless policy.origin_allowed?(origin)
      res.headers["Access-Control-Allow-Origin"] = allow_origin(policy, origin)
      res.headers["Access-Control-Allow-Credentials"] = "true" if policy.allow_credentials
      unless policy.exposed_headers.empty?
        res.headers["Access-Control-Expose-Headers"] = policy.exposed_headers.join(", ")
      end
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
      names = requested_header_names(requested)
      return false if names.nil?
      headers = policy.allowed_headers
      return true if headers.include?("*")
      i = 0
      while i < names.length
        name = names[i]
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

    def self.requested_header_names(requested)
      return [] if requested.empty?
      names = []
      parts = requested.split(",")
      i = 0
      while i < parts.length
        name = parts[i].strip
        if name.empty? || !header_name_value?(name)
          return nil
        end
        names.push(name)
        i += 1
      end
      names
    end

    def self.header_name_value?(name)
      if !name.is_a?(String) || name.empty?
        return false
      end
      i = 0
      while i < name.bytesize
        byte = name.getbyte(i)
        return false if byte < 0x21 || byte > 0x7E
        return false if byte == 0x28 || byte == 0x29 || byte == 0x3C || byte == 0x3E
        return false if byte == 0x40 || byte == 0x2C || byte == 0x3B || byte == 0x3A
        return false if byte == 0x5C || byte == 0x22 || byte == 0x2F || byte == 0x5B
        return false if byte == 0x5D || byte == 0x3F || byte == 0x3D || byte == 0x7B
        return false if byte == 0x7D
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
        return if parts[i].strip.downcase == value.downcase
        i += 1
      end
      res.headers["Vary"] = current + ", " + value
    end

    private_class_method :verb_allowed?, :request_headers_allowed?
    private_class_method :requested_header_names, :header_name_value?
    private_class_method :allow_origin, :add_vary
  end
end
