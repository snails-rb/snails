# Array — the collection helpers.
class Array
  # `deep_transform_keys { |key| ... }` — a new Array whose Hash elements
  # have the block applied to every key at every depth; non-Hash elements
  # pass through unchanged. The receiver is untouched.
  #
  # @return [Array] a new Array with the Hash elements' keys transformed
  # @example
  #   [{ "os_name" => "ios" }].deep_transform_keys { |key| key.to_s.camelize(:lower) }
  #   # => [{ "osName" => "ios" }]
  def deep_transform_keys(&block)
    map { |element| element.is_a?(Hash) ? element.deep_transform_keys(&block) : element }
  end

  # `deep_transform_keys! { |key| ... }` — the same transform in place.
  # Unlike a typed Hash's keys, an Array's elements don't change type when
  # only the Hash elements' keys reshape, so the bang form mutates the
  # receiver.
  #
  # @return [Array] this Array with the Hash elements' keys transformed
  # @example
  #   list = [{ "os_name" => "ios" }]
  #   list.deep_transform_keys! { |key| key.to_s.camelize(:lower) }
  #   list   # => [{ "osName" => "ios" }]
  def deep_transform_keys!(&block)
    map! { |element| element.is_a?(Hash) ? element.deep_transform_keys(&block) : element }
  end

  # `to_sentence(words_connector:, two_words_connector:, last_word_connector:)` —
  # the elements through `to_s` joined in reading order: `""`, `"a"`,
  # `"a and b"`, `"a, b, and c"`; each connector defaults to English prose
  # and is overridable by keyword.
  #
  # @return [String] the joined sentence
  def to_sentence(words_connector: ", ", two_words_connector: " and ", last_word_connector: ", and ")
    n = length
    return "" if n == 0
    return self[0].to_s if n == 1
    return "#{self[0]}#{two_words_connector}#{self[1]}" if n == 2
    head = +""
    i = 0
    while i < n - 1
      head = head + words_connector if i > 0
      head = head + self[i].to_s
      i = i + 1
    end
    "#{head}#{last_word_connector}#{self[n - 1]}"
  end
end
