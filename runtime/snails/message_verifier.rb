# Signed String tokens: a URL-safe base64 payload and an HMAC-SHA256
# signature under a key derived from the app's signing key and a purpose.
#
# The token format belongs to this verifier: a token minted here is read
# here. Tokens from another framework do not verify here, and this verifier
# does not mint their format. The purpose is part of the key, not the token:
# a value signed for `reset` does not verify under `cookie.session`.
require "base64"

module Snails
  # signs a String and verifies tokens it produced.
  #
  # @example
  #   verifier = Snails::MessageVerifier.new
  #   token = verifier.generate("account:42", purpose: "reset")
  #   verifier.verified(token, purpose: "reset")  # => "account:42"
  class MessageVerifier
    # @param secret [String] the signing key; defaults to the app's
    #   `SECRET_KEY_BASE` reader
    # @return [void]
    # @raise [ArgumentError] the secret is missing or not a non-empty String
    def initialize(secret = Snails.app.secret_key_base)
      if !secret.is_a?(String) || secret.empty?
        raise ArgumentError, "MessageVerifier needs a non-empty secret"
      end
      @secret = secret
    end

    # sign a String. The token is safe in a cookie or a URL segment.
    #
    # @param value [String] the value to sign
    # @param purpose [String, nil] the namespace the token belongs to
    # @return [String] the token, `payload.signature`
    # @raise [ArgumentError] the value is not a String, or the purpose is
    #   not a String or nil
    def generate(value, purpose: nil)
      if !value.is_a?(String)
        raise ArgumentError, "generate expects a String"
      end
      payload = Base64.urlsafe_encode64(value, padding: false)
      payload + "." + signature(payload, purpose)
    end

    # the value a token carries, or nil when the token was not minted by
    # this secret and purpose. A malformed token, a tampered signature, and a
    # token for another purpose all read the same — there is no error state
    # an auth path has to handle.
    #
    # @param token [String] the token to verify
    # @param purpose [String, nil] the namespace the token must belong to
    # @return [String, nil] the signed value, or nil when it does not verify
    # @raise [ArgumentError] the token is not a String, or the purpose is
    #   not a String or nil
    def verified(token, purpose: nil)
      if !token.is_a?(String)
        raise ArgumentError, "verified expects a String"
      end
      separator = token.index(".")
      return nil if separator.nil?
      payload = token[0, separator]
      supplied = token[separator + 1, token.length - separator - 1]
      return nil unless Snails::Security.secure_compare(supplied, signature(payload, purpose))
      begin
        Base64.urlsafe_decode64(payload)
      rescue ArgumentError
        nil
      end
    end

    # the HMAC over the payload text, hex-encoded. The payload is signed as
    # sent, not after a decode-and-reencode round trip.
    def signature(payload, purpose)
      Tep::Crypto.sp_crypto_hmac_sha256_hex(purpose_key(purpose), payload) + ""
    end

    # A purpose gets its own key by HMAC-ing the app secret with a fixed
    # domain string. The result is hex text used as the next HMAC's key; it
    # never leaves this verifier.
    def purpose_key(purpose)
      if !purpose.nil? && !purpose.is_a?(String)
        raise ArgumentError, "purpose must be a String or nil"
      end
      domain = purpose.nil? ? "snails.message_verifier" : "snails.message_verifier." + purpose
      Tep::Crypto.sp_crypto_hmac_sha256_hex(@secret, domain) + ""
    end

    private :signature, :purpose_key
  end
end
