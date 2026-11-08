# The request's header view — HTTP header names mapped onto the Rack-style
# keys the dispatcher stores in the request's internal env hash. Read-only:
# request headers are input, not response state.
module ActionDispatch
  module Http
    class Headers
      # The env keys that are CGI variables rather than `HTTP_`-prefixed
      # header keys. `Content-Type` and `Content-Length` are the two request
      # headers in this set.
      CGI_VARIABLES = %w[
        AUTH_TYPE CONTENT_LENGTH CONTENT_TYPE GATEWAY_INTERFACE HTTPS
        PATH_INFO PATH_TRANSLATED QUERY_STRING REMOTE_ADDR REMOTE_HOST
        REMOTE_IDENT REMOTE_USER REQUEST_METHOD SCRIPT_NAME SERVER_NAME
        SERVER_PORT SERVER_PROTOCOL SERVER_SOFTWARE
      ].freeze

      # A lookup key that is only letters, digits, and dashes is an HTTP
      # header name; an underscore means the caller already named an env key.
      HTTP_HEADER = /\A[A-Za-z0-9-]+\z/

      # The sentinel that tells `fetch` "no default was given".
      DEFAULT = Object.new

      # wrap the request's env hash. The hash is read live, so a view created
      # once sees the request's current headers.
      #
      # @param env [Hash{String => untyped}] the request's internal env hash
      # @return [Headers] the header view
      def initialize(env)
        @env = env
      end

      # the header value, or nil when absent. Accepts both an HTTP header name
      # (`Authorization`) and an env key (`HTTP_AUTHORIZATION`, `CONTENT_TYPE`).
      #
      # @param key [String] the header name or env key
      # @return [untyped] the header value, nil when absent
      # @example
      #   headers["Authorization"] # => "Bearer token"
      def [](key)
        name = env_name(key)
        return nil unless @env.key?(name)
        @env[name]
      end

      # the header value; without a default, raises KeyError when absent. An
      # empty header value is present, so it answers "" rather than the default.
      #
      # @param key [String] the header name or env key
      # @param default [untyped] the value to answer when the header is absent
      # @return [untyped] the header value, or the default
      # @raise [KeyError] the header is absent and no default was given
      def fetch(key, default = DEFAULT)
        name = env_name(key)
        if default.equal?(DEFAULT)
          @env.fetch(name)
        else
          @env.fetch(name, default)
        end
      end

      # whether the header is present. An empty value is present; only an absent
      # key answers false.
      #
      # @param key [String] the header name or env key
      # @return [Boolean] true when the header key exists
      def has_key?(key)
        @env.key?(env_name(key))
      end

      # yield each request header as a name and value. Names are normalized to
      # lowercase with dashes (`authorization`, `content-type`). Only header
      # keys are yielded; env scratch keys are skipped.
      #
      # @yieldparam name [String] the normalized header name
      # @yieldparam value [untyped] the header value
      # @return [void]
      def each_header
        @env.each do |key, value|
          name = header_name(key)
          yield(name, value) unless name.nil?
        end
      end

      # every request header as a Hash keyed by normalized name.
      #
      # @return [Hash{String => untyped}] the header names and values
      def to_h
        out = {}
        @env.each do |key, value|
          name = header_name(key)
          out[name] = value unless name.nil?
        end
        out
      end

      # the env key for a wire header name. The dispatcher uses this when
      # copying parsed headers into the request's env hash.
      #
      # @param name [String] the wire header name
      # @return [String] the Rack-style env key
      def self.env_key(name)
        key = name.to_s.upcase.tr("-", "_")
        return key if CGI_VARIABLES.include?(key)
        "HTTP_" + key
      end

      # the env key for a lookup. An underscore in the key means the caller
      # already named an env key, so it passes through.
      def env_name(key)
        key = key.to_s
        if HTTP_HEADER.match?(key)
          Headers.env_key(key)
        else
          key
        end
      end

      # the inverse for iteration: `HTTP_X_FOO` → `x-foo`, `CONTENT_TYPE` →
      # `content-type`, anything else nil.
      def header_name(key)
        if key.start_with?("HTTP_")
          key[5, key.length - 5].to_s.downcase.tr("_", "-")
        elsif key == "CONTENT_TYPE" || key == "CONTENT_LENGTH"
          key.downcase.tr("_", "-")
        else
          nil
        end
      end

      private :env_name, :header_name
    end
  end
end
