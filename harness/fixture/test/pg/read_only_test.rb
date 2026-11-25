require_relative "../test_helper"
require_relative "../harness_runner"
require_relative "../test_database"

# Sqlx::Connection.open(read_only: true) (PostgreSQL) — the explicit connection
# returns ordered columns and value arrays, caps rows, times out a long
# statement, and refuses writes through a per-query read-only transaction.
class PgReadOnlyTest < TestBase
  def setup
    TestDatabase.configure!("read_only", pool_size: 2)
    TestDatabase.drop_tables!("read_only_samples")
    TestDatabase.exec("CREATE TABLE read_only_samples (id INTEGER PRIMARY KEY, service TEXT NOT NULL, n INTEGER NOT NULL)")
    TestDatabase.exec("INSERT INTO read_only_samples (service, n) VALUES ('telemetry', 10), ('pandaspeed', 20), ('telemetry', 30)")
  end

  def assert_equal(expected, actual, msg = nil)
    raise(msg || "expected #{expected.inspect}, got #{actual.inspect}") unless expected == actual
  end

  def read(sql, max_rows: 10, timeout_ms: 1_000)
    Sqlx::Connection.open(read_only: true) do |conn|
      conn.query(sql, max_rows: max_rows, timeout_ms: timeout_ms)
    end
  end

  # A recursive CTE that runs far past a short timeout on every machine.
  def long_query
    "WITH RECURSIVE cnt(x) AS (VALUES(0) UNION ALL SELECT x + 1 FROM cnt WHERE x < 100000000) SELECT count(*) FROM cnt"
  end

  # A plain SELECT returns the select-list names in order and one value array
  # per row.
  def test_returns_columns_and_array_rows
    result = read("SELECT service, n FROM read_only_samples ORDER BY id")
    assert_equal ["service", "n"], result.columns
    assert_equal [["telemetry", 10], ["pandaspeed", 20], ["telemetry", 30]], result.rows
    assert_equal 3, result.row_count
    assert_equal false, result.truncated?
  end

  # A zero-row result keeps the columns, so the caller can render an empty
  # table with the right shape.
  def test_zero_rows_still_returns_columns
    result = read("SELECT service, n FROM read_only_samples WHERE 1 = 0")
    assert_equal ["service", "n"], result.columns
    assert_equal [], result.rows
    assert_equal 0, result.row_count
    assert_equal false, result.truncated?
  end

  # Rows are value arrays, not hashes: a duplicate select-list name keeps both
  # values in order.
  def test_duplicate_column_names_are_preserved
    result = read("SELECT id, id FROM read_only_samples ORDER BY id LIMIT 1")
    assert_equal ["id", "id"], result.columns
    assert_equal [[1, 1]], result.rows
  end

  # max_rows bounds the returned rows and truncated? reports that more were
  # available.
  def test_row_cap_and_truncated
    result = read("SELECT id FROM read_only_samples ORDER BY id", max_rows: 2)
    assert_equal [[1], [2]], result.rows
    assert_equal 2, result.row_count
    assert_equal true, result.truncated?
  end

  # One connection can run more than one query: the app reads a value and then
  # the data it needs.
  def test_two_queries_share_one_connection
    values = Sqlx::Connection.open(read_only: true) do |conn|
      first = conn.query("SELECT 1 AS one", max_rows: 10, timeout_ms: 1_000)
      data = conn.query("SELECT n FROM read_only_samples ORDER BY id LIMIT 1", max_rows: 10, timeout_ms: 1_000)
      [ first.rows[0][0], data.rows[0][0] ]
    end
    assert_equal 1, values[0]
    assert_equal 10, values[1]
  end

  # A trailing semicolon is not a second statement.
  def test_trailing_semicolon_is_one_statement
    result = read("SELECT 1 AS one;")
    assert_equal [[1]], result.rows
  end

  # A trailing comment is not a second statement.
  def test_trailing_comment_is_one_statement
    result = read("SELECT 1 AS one; -- done")
    assert_equal [[1]], result.rows
  end

  # A second statement after the first is refused before it can run.
  def test_multiple_statements_are_rejected
    raised = nil
    begin
      read("SELECT 1; SELECT 2")
    rescue ArgumentError => e
      raised = e
    end
    assert_equal true, !raised.nil?
  end

  # SQL with no statement (only comments or whitespace) is a caller error.
  def test_sql_without_a_statement_is_rejected
    raised = nil
    begin
      read("-- only a comment")
    rescue ArgumentError => e
      raised = e
    end
    assert_equal true, !raised.nil?
  end

  # The connection refuses a write through the read-only transaction.
  def test_read_only_connection_rejects_writes
    raised = nil
    begin
      read("INSERT INTO read_only_samples (service, n) VALUES ('x', 1)")
    rescue Sqlx::ReadOnlyError => e
      raised = e
    end
    assert_equal true, !raised.nil?
  end

  # A locking read is a write-class statement; the read-only transaction
  # refuses it.
  def test_select_for_update_is_rejected
    raised = nil
    begin
      read("SELECT * FROM read_only_samples FOR UPDATE")
    rescue Sqlx::ReadOnlyError => e
      raised = e
    end
    assert_equal true, !raised.nil?
  end

  # EXPLAIN is not a cursor query; the savepoint fallback runs it through the
  # extended protocol and returns its rows.
  def test_explain_runs_through_the_fallback
    result = read("EXPLAIN SELECT n FROM read_only_samples ORDER BY id")
    assert_equal ["QUERY PLAN"], result.columns
    assert_equal true, result.row_count > 0
  end

  # COPY can write server files; the connection refuses the copy status and
  # closes instead of draining it.
  def test_copy_is_rejected
    raised = nil
    begin
      read("COPY (SELECT 1) TO STDOUT")
    rescue Sqlx::ConnectionFailed => e
      raised = e
    end
    assert_equal true, !raised.nil?
  end

  # statement_timeout stops a statement that runs past the limit.
  def test_timeout_aborts_a_long_query
    raised = nil
    begin
      read(long_query, timeout_ms: 50)
    rescue Sqlx::QueryTimeout => e
      raised = e
    end
    assert_equal true, !raised.nil?
  end

  # A timeout interrupts the statement, not the connection, so the next query
  # on the same connection succeeds.
  def test_connection_survives_a_timeout
    Sqlx::Connection.open(read_only: true) do |conn|
      timed_out = false
      begin
        conn.query(long_query, max_rows: 10, timeout_ms: 50)
      rescue Sqlx::QueryTimeout
        timed_out = true
      end
      assert_equal true, timed_out
      result = conn.query("SELECT 1 AS one", max_rows: 10, timeout_ms: 1_000)
      assert_equal [[1]], result.rows
    end
  end

  # The connection validates the execution limits at the query entry point.
  def test_non_positive_limits_are_rejected
    Sqlx::Connection.open(read_only: true) do |conn|
      [ [ 0, 1_000 ], [ -1, 1_000 ], [ 10, 0 ], [ 10, -1 ] ].each do |limits|
        raised = nil
        begin
          conn.query("SELECT 1", max_rows: limits[0], timeout_ms: limits[1])
        rescue ArgumentError => e
          raised = e
        end
        assert_equal true, !raised.nil?
      end
    end
  end

  # The connection reports its mode.
  def test_read_only_predicate
    Sqlx::Connection.open(read_only: true) do |conn|
      assert_equal true, conn.read_only?
    end
  end

  # A raw writable connection is not exposed yet; the mode is explicit and the
  # refusal is loud.
  def test_raw_writable_connections_are_not_exposed_yet
    raised = nil
    begin
      Sqlx::Connection.open(read_only: false)
    rescue NotImplementedError => e
      raised = e
    end
    assert_equal true, !raised.nil?
  end

  # The no-block form returns the connection; close is idempotent, and a query
  # after close fails before it reaches the closed session.
  def test_no_block_form_close_is_idempotent
    conn = Sqlx::Connection.open(read_only: true)
    result = conn.query("SELECT 1 AS one", max_rows: 10, timeout_ms: 1_000)
    assert_equal [[1]], result.rows
    conn.close
    conn.close
    raised = nil
    begin
      conn.query("SELECT 1 AS one", max_rows: 10, timeout_ms: 1_000)
    rescue ArgumentError => e
      raised = e
    end
    assert_equal true, !raised.nil?
  end

  # The optional first argument opens the named database instead of the
  # configured one.
  def test_explicit_database_path_is_read
    result = Sqlx::Connection.open(ENV["PG_URL"], read_only: true) do |conn|
      conn.query("SELECT n FROM read_only_samples ORDER BY id LIMIT 1", max_rows: 10, timeout_ms: 1_000)
    end
    assert_equal [[10]], result.rows
  end
end

FixtureRunner.run(PgReadOnlyTest, [
  "test_returns_columns_and_array_rows",
  "test_zero_rows_still_returns_columns",
  "test_duplicate_column_names_are_preserved",
  "test_row_cap_and_truncated",
  "test_two_queries_share_one_connection",
  "test_trailing_semicolon_is_one_statement",
  "test_trailing_comment_is_one_statement",
  "test_multiple_statements_are_rejected",
  "test_sql_without_a_statement_is_rejected",
  "test_read_only_connection_rejects_writes",
  "test_select_for_update_is_rejected",
  "test_explain_runs_through_the_fallback",
  "test_copy_is_rejected",
  "test_timeout_aborts_a_long_query",
  "test_connection_survives_a_timeout",
  "test_non_positive_limits_are_rejected",
  "test_read_only_predicate",
  "test_raw_writable_connections_are_not_exposed_yet",
  "test_no_block_form_close_is_idempotent",
  "test_explicit_database_path_is_read"
])
