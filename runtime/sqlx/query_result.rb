module Sqlx
  # One read query's answer: the statement's column names in select order, its
  # rows as value arrays, and whether the row cap cut the result.
  #
  # This is the result of a row-returning read. A write path needs its own
  # result type for affected rows; `truncated?` and `row_count` describe a row
  # set, not a statement's change count.
  #
  # Rows are arrays rather than column-name hashes because arbitrary SQL can
  # project the same name twice (`SELECT a.id, b.id`) and the caller must keep
  # both values in order. A zero-row result still carries the columns, which
  # is what tells a caller the shape of an empty answer. Values are the
  # adapter's native types, the same contract `rows_by_sql` returns; treat the
  # arrays as read-only.
  class QueryResult
    # @param columns [Array<String>] the select-list names, in order
    # @param rows [Array<Array>] one value array per row, at most the cap; values
    #   are the adapter's native types
    # @param truncated [Boolean] true when the statement had more rows than the
    #   cap allowed
    def initialize(columns, rows, truncated)
      @columns = columns
      @rows = rows
      @truncated = truncated
    end

    # @return [Array<String>] the select-list names, in order
    def columns = @columns

    # @return [Array<Array>] one value array per row, in statement order; values
    #   are the adapter's native types
    def rows = @rows

    # @return [Integer] the number of rows actually returned (never the
    #   statement's full count when the cap cut it)
    def row_count = @rows.length

    # @return [Boolean] true when the statement had more rows than the cap
    def truncated? = @truncated
  end
end
