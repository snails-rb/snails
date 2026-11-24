module Sqlx
  # One dedicated read-only connection, yielded by
  # `Sqlx::Base.with_read_only`. The scope owns the connection: it opens before
  # the block and closes after it, including when the block raises.
  #
  # The connection refuses writes and `ATTACH` at the database layer; the
  # caller's statement policy (which statements to allow) stays in the app.
  class ReadConnection
    # @param handle [untyped] the adapter's open connection handle
    # @param max_rows [Integer] the per-query row cap
    # @param timeout_ms [Integer] the per-query wall-clock limit
    def initialize(handle, max_rows, timeout_ms)
      @handle = handle
      @max_rows = max_rows
      @timeout_ms = timeout_ms
    end

    # Runs one read-only statement on this connection.
    #
    # The statement must be a single statement; a second statement after the
    # first is refused. The statement takes no bound values. The result carries
    # the columns, at most `max_rows` rows, and whether the cap cut the answer.
    #
    # @param sql [String] one SQL statement
    # @return [Sqlx::QueryResult] the columns, capped rows, and truncation flag
    # @raise [ArgumentError] the statement is empty or carries more than one
    #   statement
    # @raise [Sqlx::QueryTimeout] the statement exceeded the timeout
    # @raise [Sqlx::ReadOnlyViolation] the statement tried to write
    # @raise [Sqlx::Busy] the database lock stayed held past the busy timeout
    def query(sql)
      Sqlx::Database.exec_query(@handle, sql, max_rows: @max_rows, timeout_ms: @timeout_ms)
    end

    # Closes the connection. The `with_read_only` scope calls it; a caller
    # holding the reader must not close it.
    #
    # @return [void]
    def close
      Sqlx::Database.close_read_only(@handle)
    end
  end
end
