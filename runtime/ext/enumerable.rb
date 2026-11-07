# Enumerable — the collection predicates and projections.
module Enumerable
  # `index_by { |element| key }` — the collection as a Hash keyed by the
  # block's value; last write wins on duplicates.
  #
  # @return [Hash] this collection keyed by the block's value
  def index_by
    h = {}
    each { |x| h[yield x] = x }
    h
  end

  # `many?()` — more than one element.
  #
  # `length` answers it because everything that reaches here is already
  # materialized.
  #
  # @return [Boolean] true when the collection holds two or more elements
  def many?
    length > 1
  end

  # `sole()` — the one element, asserting the count instead of only reading
  # the first: `first` would keep the read and drop the assertion.
  #
  # @return [untyped] the collection's single element
  # @raise [RuntimeError] the collection is empty or holds more than one element
  def sole
    n = length
    raise "no item found" if n == 0
    raise "multiple items found" if n > 1
    self[0]
  end
end
