# Constant-time String comparison for tokens and signatures: the loop
# reads both Strings to the end, so the time taken does not say how many
# leading bytes of a forged value matched.
#
# The length check exits early. Length is not secret for the values this
# serves — a token or a hex digest has one fixed length for its issuer — and
# a constant-time loop over different lengths has no defined answer.
module Snails
  # compare two Strings without leaking a matching prefix through timing.
  #
  # @param a [String] the first value
  # @param b [String] the second value
  # @return [Boolean] true when the bytes are equal
  # @raise [ArgumentError] either value is not a String
  # @example
  #   Snails.secure_compare(presented_token, expected_token)
  def self.secure_compare(a, b)
    if !a.is_a?(String) || !b.is_a?(String)
      raise ArgumentError, "secure_compare expects two Strings"
    end
    return false if a.bytesize != b.bytesize
    diff = 0
    i = 0
    while i < a.bytesize
      diff = diff | (a.getbyte(i) ^ b.getbyte(i))
      i += 1
    end
    diff == 0
  end
end
