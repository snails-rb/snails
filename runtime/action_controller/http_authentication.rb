# HTTP Token and Basic authentication helpers on the controller: the
# `authenticate_with_*` forms answer the block's value (nil when the scheme's
# header is absent), and the `or_request` forms answer 401 and mark the
# response performed, halting the filter chain. Token options are String-keyed;
# a pair with no value maps to "" so the Hash stays one concrete type.
module ActionController
  class API
    # yield the presented token and its options to the block. No challenge goes
    # out: a header without a Token or Bearer credential answers nil, and the
    # caller decides what to do about it.
    #
    # @return [Object, nil] the block's answer; nil when the request
    #   carried no token
    def authenticate_with_http_token
      token = token_from(HttpAuthentication.authorization(self))
      return nil if token.empty?
      yield(token, token_options(HttpAuthentication.authorization(self)))
    end

    # yield the presented token and its options to the block. A falsy answer, or
    # no token at all, sends a 401 with the Token challenge and marks the
    # response performed, which halts the filter chain.
    #
    # The block is yielded to directly rather than forwarded to
    # `authenticate_with_http_token`: an explicit `&block` parameter is a Proc
    # value, which the AOT path types far less precisely than a `yield` it
    # can see the caller's block for.
    #
    # @param realm [String] realm the 401 challenge states
    # @param message [String, nil] the 401 body; nil sends the default text
    # @return [Object, nil] the block's answer; nil when no token arrived
    def authenticate_or_request_with_http_token(realm = "Application", message = nil)
      header = HttpAuthentication.authorization(self)
      token = token_from(header)
      result = token.empty? ? nil : yield(token, token_options(header))
      request_http_token_authentication(realm, message) unless result
      result
    end

    # answer the request with a 401 whose `WWW-Authenticate` carries the Token
    # challenge. The render marks the response performed, so the filter chain
    # stops here.
    #
    # @param realm [String] the realm the challenge states
    # @param message [String, nil] the 401 body; nil sends the default text
    # @return [void]
    def request_http_token_authentication(realm = "Application", message = nil)
      headers["WWW-Authenticate"] = "Token realm=\"#{realm.delete("\"")}\""
      render(message.nil? ? "HTTP Token: Access denied.\n" : message,
        status: :unauthorized, content_type: "text/plain; charset=utf-8")
    end

    # yield the presented Basic credentials to the block. No challenge goes out:
    # a header without Basic credentials answers nil, and the caller decides
    # what to do about it.
    #
    # @return [Object, nil] the block's answer; nil when the request
    #   carried no Basic credentials
    def authenticate_with_http_basic
      header = HttpAuthentication.authorization(self)
      return nil unless basic?(header)
      pair = basic_credentials(header)
      yield(pair[0], pair[1])
    end

    # yield the presented credentials to the block. A falsy answer, or no Basic
    # credentials at all, sends a 401 with the Basic challenge and marks the
    # response performed, which halts the filter chain.
    #
    # @param realm [String] realm the 401 challenge states
    # @param message [String, nil] the 401 body; nil sends the default text
    # @return [Object, nil] the block's answer; nil when no credentials
    #   arrived
    def authenticate_or_request_with_http_basic(realm = "Application", message = nil)
      header = HttpAuthentication.authorization(self)
      result = nil
      if basic?(header)
        pair = basic_credentials(header)
        result = yield(pair[0], pair[1])
      end
      request_http_basic_authentication(realm, message) unless result
      result
    end

    # answer the request with a 401 whose `WWW-Authenticate` carries the Basic
    # challenge. The render marks the response performed, so the filter chain
    # stops here.
    #
    # @param realm [String] the realm the challenge states
    # @param message [String, nil] the 401 body; nil sends the default text
    # @return [void]
    def request_http_basic_authentication(realm = "Application", message = nil)
      headers["WWW-Authenticate"] = "Basic realm=\"#{realm.delete("\"")}\""
      render(message.nil? ? "HTTP Basic: Access denied.\n" : message,
        status: :unauthorized, content_type: "text/plain; charset=utf-8")
    end

    # Private on purpose: the authenticate_* methods above are the entries;
    # the header parser is free to change without notice.

    # The `key=value` pairs after the scheme, the first one keyed
    # `token` whether or not the client wrote `token=`; empty when the
    # scheme is neither Token nor Bearer.
    def token_pairs(header)
      pairs = []
      rest = nil
      if header.start_with?("Token ")
        rest = header[6, header.length].to_s
      elsif header.start_with?("Bearer ")
        rest = header[7, header.length].to_s
      end
      return pairs if rest.nil?
      rest.tr(";\t", ",,").split(",").each do |raw|
        param = raw.strip
        next if param.empty?
        param = "token=#{param}" if pairs.empty? && !param.start_with?("token=")
        at = param.index("=")
        key = at.nil? ? param : param[0, at].to_s
        value = at.nil? ? "" : param[at + 1, param.length].to_s
        pairs << [key, unquote(value)]
      end
      pairs
    end

    # The token itself: the first pair's value.
    def token_from(header)
      pairs = token_pairs(header)
      return "" if pairs.empty?
      pairs[0][1].to_s
    end

    # Every pair after the token, as the block's `options`.
    def token_options(header)
      options = {}
      token_pairs(header).each_with_index do |pair, i|
        options[pair[0].to_s] = pair[1].to_s if i > 0
      end
      options
    end

    # Equivalent to `gsub(/^"|"$/, "")`: one quote off each end,
    # independently.
    def unquote(value)
      v = value
      v = v[1, v.length].to_s if v.start_with?("\"")
      v = v[0, v.length - 1].to_s if v.end_with?("\"")
      v
    end

    def basic?(header)
      header.split(" ", 2)[0].to_s.downcase == "basic"
    end

    # `[user, password]`, both "" when the payload is missing; a
    # password may itself hold colons.
    def basic_credentials(header)
      decoded = Base64.decode64(header.split(" ", 2)[1].to_s)
      at = decoded.index(":")
      return [decoded, ""] if at.nil?
      [decoded[0, at].to_s, decoded[at + 1, decoded.length].to_s]
    end
    private :token_pairs, :token_from, :token_options, :unquote, :basic?, :basic_credentials
  end

  module HttpAuthentication
    # the request's Authorization header value.
    #
    # @param controller [ActionController::API] the controller holding the request
    # @return [String] the header value, or "" outside a dispatch — a
    #   controller built by hand has no request
    def self.authorization(controller)
      req = controller.request
      return "" if req.nil?
      req.headers["Authorization"].to_s
    end
  end
end
