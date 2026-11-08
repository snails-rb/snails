# Object — the blank-value predicates, over every receiver.
#
# One generic method answers for every receiver, so `x.blank?` cannot drift
# from `y.blank?` by the receiver's class.
#
# Reopening Object relies on the pinned toolchain keeping dynamic
# `Object.const_get` intact (a store-backed job adapter resolves stored names
# that way; upstream 463242126 carries the fix).
class Object
  # the generic emptiness predicate: nil, false, an empty Array/Hash, and a
  # whitespace-only String are blank. Every other value is present: `0` and
  # `:sym` are values, not emptiness, and a String is judged by its own text
  # (`""` and `"  "` are blank).
  #
  # @return [Boolean] true when the receiver holds nothing
  # @example
  #   nil.blank?    # => true
  #   " ".blank?    # => true
  #   [].blank?     # => true
  #   0.blank?      # => false
  def blank?
    return true if nil?
    return true if self == false
    return empty? if is_a?(Array)
    return empty? if is_a?(Hash)
    to_s.strip.empty?
  end

  # the negation of `blank?`, for call sites that read better in the positive.
  #
  # @return [Boolean] true when the receiver holds something
  # @example
  #   "x".present?  # => true
  #   [].present?   # => false
  def present?
    !blank?
  end

  # the receiver when present, nil when blank: the `x.presence || fallback`
  # shape replaces `blank? ? nil : x` at the call site.
  #
  # @return [Object, nil] the receiver itself, or nil when blank
  # @example
  #   "x".presence  # => "x"
  #   "".presence   # => nil
  def presence
    blank? ? nil : self
  end

  # the receiver when it is in the allow-list, nil otherwise: the gate for a
  # value that came off the wire, with the list naming the allowed values.
  # Membership compares the receiver's text, so a Symbol value matches its
  # String spelling in both kinds of list; a non-Array list is rejected at the
  # call — a String would silently substring-match.
  #
  # @param list [Array<String>] the allow-list of values
  # @return [Object, nil] the receiver itself, or nil when not listed
  # @raise [ArgumentError] the allow-list is not an Array
  # @example
  #   "member".presence_in(["member", "admin"])  # => "member"
  #   "other".presence_in(["member", "admin"])   # => nil
  def presence_in(list)
    unless list.is_a?(Array)
      raise ArgumentError, "presence_in expects the allow-list as an Array, got #{list.class}"
    end

    list.include?(to_s) ? self : nil
  end
end
