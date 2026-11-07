require_relative "../test_helper"
require_relative "../harness_runner"

# The pg-only half of the request-cache contract (a locking read is not cached)
# plus the pg half of the contention contract (a lock wait failure is
# `Sqlx::Busy`, the same type sqlite's busy handler raises). SQLite has no
# FOR UPDATE and no second connection in this adapter, so both run in the pg
# gate only — the shared cases live in sqlx_request_cache_test.rb.
Sqlx::Database.configure(ENV["PG_URL"].to_s)

class PgLockingReadTest < TestBase
  def setup
    Sqlx::Database.exec("DROP TABLE IF EXISTS locking_items")
    Sqlx::Database.exec("CREATE TABLE locking_items (id INTEGER PRIMARY KEY, name TEXT NOT NULL)")
    Sqlx::Database.exec("INSERT INTO locking_items (id, name) VALUES (1, 'alpha')")
  end

  def assert_equal(expected, actual, msg = nil)
    raise(msg || "expected #{expected.inspect}, got #{actual.inspect}") unless expected == actual
  end

  # A second libpq connection for the test to hold a lock on. Raw FFI on
  # purpose: the adapter keeps one shared connection, and a lock the test
  # cannot release would wedge the rest of the file.
  def raw_connect
    conn = Sqlx::Database::Libpq.PQconnectdb(ENV["PG_URL"].to_s)
    if Sqlx::Database::Libpq.PQstatus(conn) != Sqlx::Database::Libpq::CONNECTION_OK
      message = Sqlx::Database::Libpq.PQerrorMessage(conn)
      Sqlx::Database::Libpq.PQfinish(conn)
      raise "raw pg connect failed: " + message
    end
    conn
  end

  def raw_exec(conn, sql)
    res = Sqlx::Database::Libpq.PQexec(conn, sql)
    Sqlx::Database::Libpq.PQclear(res)
    nil
  end

  # When another connection holds the table in ACCESS EXCLUSIVE and the adapter
  # connection exceeds lock_timeout, expect: driver SQLSTATE 55P03 is raised as
  # `Sqlx::Busy`, and a read on the same connection succeeds after the lock is
  # released.
  def test_a_lock_wait_failure_raises_sqlx_busy
    other = raw_connect
    begin
      raw_exec(other, "BEGIN")
      raw_exec(other, "LOCK TABLE locking_items IN ACCESS EXCLUSIVE MODE")
      Sqlx::Database.exec("SET lock_timeout TO '100ms'")

      raised = nil
      began = Time.now
      begin
        Sqlx::Base.rows_by_sql("SELECT name FROM locking_items WHERE id = 1", [])
      rescue => e
        raised = e
      end
      elapsed = Time.now - began

      assert_equal "Sqlx::Busy", raised.class.to_s
      assert_equal true, elapsed < 1.0
    ensure
      raw_exec(other, "ROLLBACK")
      Sqlx::Database::Libpq.PQfinish(other)
      Sqlx::Database.exec("SET lock_timeout TO DEFAULT")
    end

    rows = Sqlx::Base.rows_by_sql("SELECT name FROM locking_items WHERE id = 1", [])
    assert_equal "alpha", rows[0]["name"]
  end

  # A locking read is not cached: both statements reach the server.
  def test_locking_read_is_not_cached
    Sqlx::Database.with_connection do
      first = Sqlx::Base.rows_by_sql("SELECT name FROM locking_items /* pg_cache_lock */ WHERE id = 1 FOR UPDATE")
      second = Sqlx::Base.rows_by_sql("SELECT name FROM locking_items /* pg_cache_lock */ WHERE id = 1 FOR UPDATE")
      assert_equal "alpha", first[0]["name"]
      assert_equal "alpha", second[0]["name"]
    end
  end
end

FixtureRunner.run(PgLockingReadTest, [
  "test_a_lock_wait_failure_raises_sqlx_busy",
  "test_locking_read_is_not_cached"
])
