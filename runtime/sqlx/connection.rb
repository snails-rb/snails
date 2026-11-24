module Sqlx
  # One explicitly opened database connection. The model pool is the default
  # path for app queries; this handle is for callers that need their own
  # connection, such as a read-only scope for SQL built at runtime.
  #
  # `open(read_only: true)` asks the adapter for a connection that refuses
  # writes at the database layer. A raw writable connection is not exposed yet;
  # `read_only: false` raises NotImplementedError.
  class Connection
    # Opens one connection. With a block, yields it and closes it afterwards,
    # including when the block raises; without a block, returns it for the
    # caller to close.
    #
    # @param database [String, nil] the adapter's database path or connection
    #   string; nil uses the configured database
    # @param read_only [Boolean] true for a database-enforced read-only
    #   connection; false is not exposed yet
    # @return [Sqlx::Connection, Object] the connection when no block is given,
    #   otherwise the block's value
    # @raise [ArgumentError] database is not a String or nil, or read_only is
    #   not true or false
    # @raise [NotImplementedError] the adapter does not support the requested
    #   mode or connection kind yet
    # @raise [RuntimeError] the adapter could not open the database (not
    #   configured, or not file-backed on SQLite)
    def self.open(database = nil, read_only:)
      unless database.nil? || database.is_a?(String)
        raise ArgumentError, "database must be a String or nil"
      end
      unless read_only == true || read_only == false
        raise ArgumentError, "read_only must be true or false"
      end
      handle = Sqlx::Database.open_connection(database, read_only: read_only)
      connection = new(handle, read_only)
      if block_given?
        begin
          yield connection
        ensure
          connection.close
        end
      else
        connection
      end
    end

    # @param handle [untyped] the adapter's open connection handle
    # @param read_only [Boolean] the mode the handle was opened with
    def initialize(handle, read_only)
      @handle = handle
      @read_only = read_only
    end

    # @return [Boolean] true when the connection refuses writes at the database
    #   layer
    def read_only? = @read_only

    # Runs one SQL statement and returns its rows in select order. The
    # connection's mode decides whether writes are allowed; a read-only
    # connection refuses them. The statement must be a single statement; the
    # row cap and wall-clock timeout are per-query execution options.
    #
    # @param sql [String] one SQL statement
    # @param max_rows [Integer] the row cap
    # @param timeout_ms [Integer] the wall-clock limit
    # @return [Sqlx::QueryResult] columns, capped rows, truncation flag
    # @raise [ArgumentError] the connection is closed, the statement is empty
    #   or carries more than one statement, or either limit is not a positive
    #   Integer
    # @raise [Sqlx::QueryTimeout] the statement exceeded the timeout
    # @raise [Sqlx::ReadOnlyError] the statement tried to write on a
    #   read-only connection
    # @raise [Sqlx::Busy] the database lock stayed held past the busy timeout
    def query(sql, max_rows:, timeout_ms:)
      handle = @handle
      raise ArgumentError, "connection is closed" if handle.nil?
      unless sql.is_a?(String) && !sql.empty?
        raise ArgumentError, "SQL must be a non-empty String"
      end
      unless max_rows.is_a?(Integer) && max_rows > 0
        raise ArgumentError, "max_rows must be a positive Integer"
      end
      unless timeout_ms.is_a?(Integer) && timeout_ms > 0
        raise ArgumentError, "timeout_ms must be a positive Integer"
      end
      Sqlx::Database.exec_query(handle, sql, max_rows: max_rows, timeout_ms: timeout_ms)
    end

    # Closes the connection. The block form of `open` calls it; a caller
    # holding a connection from the no-block form calls it. Closing an already
    # closed connection is a no-op.
    #
    # @return [void]
    def close
      handle = @handle
      return if handle.nil?
      @handle = nil
      Sqlx::Database.close_connection(handle)
    end

    private_class_method :new
  end
end
