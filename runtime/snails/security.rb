# Constant-time String comparison for tokens and signatures: the loop
# reads both Strings to the end, so the time taken does not say how many
# leading bytes of a forged value matched.
#
# A length mismatch returns false before the byte loop, so no prefix
# comparison runs. The fixed-length helper is private; secure_compare is the
# public API.
module Snails
  module Security
    # Compares two Strings without leaking a matching prefix through timing.
    # A length mismatch returns false immediately.
    #
    # @param a [String] the first value
    # @param b [String] the second value
    # @return [Boolean] true when the bytes are equal
    # @raise [ArgumentError] either value is not a String
    # @example
    #   Snails::Security.secure_compare(presented_token, expected_token)
    def self.secure_compare(a, b)
      if !a.is_a?(String) || !b.is_a?(String)
        raise ArgumentError, "secure_compare expects two Strings"
      end
      return false if a.bytesize != b.bytesize
      fixed_length_secure_compare(a, b)
    end

    # Compares two Strings of equal length without leaking a matching prefix
    # through timing. Internal: secure_compare calls this; apps use
    # secure_compare.
    #
    # @param a [String] the first value
    # @param b [String] the second value
    # @return [Boolean] true when the bytes are equal
    # @raise [ArgumentError] either value is not a String, or the lengths differ
    def self.fixed_length_secure_compare(a, b)
      if !a.is_a?(String) || !b.is_a?(String)
        raise ArgumentError, "fixed_length_secure_compare expects two Strings"
      end
      if a.bytesize != b.bytesize
        raise ArgumentError, "fixed_length_secure_compare needs equal lengths"
      end
      diff = 0
      i = 0
      while i < a.bytesize
        diff = diff | (a.getbyte(i) ^ b.getbyte(i))
        i += 1
      end
      diff == 0
    end

    private_class_method :fixed_length_secure_compare
  end
end
