module Sqlx
  # One read-only query's answer: the statement's column names in select
  # order, its rows as value arrays, and whether the row cap cut the result.
  #
  # Rows are arrays rather than column-name hashes because arbitrary SQL can
  # project the same name twice (`SELECT a.id, b.id`) and the caller must keep
  # both values in order. A zero-row result still carries the columns, which
  # is what tells a caller the shape of an empty answer.
  class ReadResult
    # @param columns [Array<String>] the select-list names, in order
    # @param rows [Array<Array>] one value array per row, at most the cap
    # @param truncated [Boolean] true when the statement had more rows than the
    #   cap allowed
    def initialize(columns, rows, truncated)
      @columns = columns
      @rows = rows
      @truncated = truncated
    end

    # @return [Array<String>] the select-list names, in order
    def columns = @columns

    # @return [Array<Array>] one value array per row, in statement order
    def rows = @rows

    # @return [Integer] the number of rows actually returned (never the
    #   statement's full count when the cap cut it)
    def row_count = @rows.length

    # @return [Boolean] true when the statement had more rows than the cap
    def truncated? = @truncated
  end
end
