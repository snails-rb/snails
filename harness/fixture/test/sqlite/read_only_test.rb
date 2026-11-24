require_relative "../test_helper"
require_relative "../harness_runner"
require_relative "../test_database"

# Sqlx::Connection.open(read_only: true) (SQLite) — the explicit connection
# returns ordered columns and value arrays, caps rows, times out a long
# statement, and refuses writes, ATTACH, and a second statement.
class ReadOnlyTest < TestBase
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

  # One connection can run more than one statement: the app reads the database
  # clock and then the data it needs.
  def test_two_queries_share_one_connection
    values = Sqlx::Connection.open(read_only: true) do |conn|
      now = conn.query("SELECT datetime('now') AS now", max_rows: 10, timeout_ms: 1_000)
      data = conn.query("SELECT n FROM read_only_samples ORDER BY id LIMIT 1", max_rows: 10, timeout_ms: 1_000)
      [ now.rows[0][0], data.rows[0][0] ]
    end
    assert_equal true, values[0].is_a?(String)
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

  # The connection itself refuses a write, so a statement policy mistake
  # cannot change data.
  def test_read_only_connection_rejects_writes
    raised = nil
    begin
      read("INSERT INTO read_only_samples (service, n) VALUES ('x', 1)")
    rescue Sqlx::ReadOnlyViolation => e
      raised = e
    end
    assert_equal true, !raised.nil?
  end

  # ATTACH cannot open another database file on the node.
  def test_attach_is_rejected
    raised = nil
    begin
      read("ATTACH DATABASE ':memory:' AS other")
    rescue => e
      raised = e
    end
    assert_equal true, !raised.nil?
  end

  # The progress handler stops a statement that runs past the scope's
  # wall-clock limit.
  def test_timeout_aborts_a_long_query
    raised = nil
    begin
      read(
        "WITH RECURSIVE cnt(x) AS (VALUES(0) UNION ALL SELECT x + 1 FROM cnt WHERE x < 100000000) SELECT count(*) FROM cnt",
        timeout_ms: 50
      )
    rescue Sqlx::QueryTimeout => e
      raised = e
    end
    assert_equal true, !raised.nil?
  end

  # The connection validates the execution limits at the query entry point.
  def test_non_positive_limits_are_rejected
    raised = nil
    begin
      Sqlx::Connection.open(read_only: true) do |conn|
        conn.query("SELECT 1", max_rows: 0, timeout_ms: 1_000)
      end
    rescue ArgumentError => e
      raised = e
    end
    assert_equal true, !raised.nil?
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

  # A read-only connection to an in-memory database would be a separate empty
  # database, so the connection refuses it.
  def test_in_memory_database_is_rejected
    Sqlx::Database.close
    Sqlx::Database.configure(":memory:", pool_size: 1)
    raised = nil
    begin
      Sqlx::Connection.open(read_only: true) do |conn|
        conn.query("SELECT 1", max_rows: 10, timeout_ms: 1_000)
      end
    rescue RuntimeError => e
      raised = e
    end
    assert_equal true, !raised.nil?
  end
end

FixtureRunner.run(ReadOnlyTest, [
  "test_returns_columns_and_array_rows",
  "test_zero_rows_still_returns_columns",
  "test_duplicate_column_names_are_preserved",
  "test_row_cap_and_truncated",
  "test_two_queries_share_one_connection",
  "test_trailing_semicolon_is_one_statement",
  "test_trailing_comment_is_one_statement",
  "test_multiple_statements_are_rejected",
  "test_read_only_connection_rejects_writes",
  "test_attach_is_rejected",
  "test_timeout_aborts_a_long_query",
  "test_non_positive_limits_are_rejected",
  "test_read_only_predicate",
  "test_raw_writable_connections_are_not_exposed_yet",
  "test_in_memory_database_is_rejected"
])
