require_relative "../test_helper"
require_relative "../harness_runner"

# A pool checkout that cannot get a free connection must fail loudly inside
# the wait budget, not park the request forever. One connection and a short
# budget keep the case deterministic; the holder sleeps long enough for the
# timeout to fire. Configure in `setup` so this file's short budget does not
# leak into another case file the bundle requires before its own runner exits.
class PgPoolTimeoutTest < TestBase
  def setup
    ENV["DATABASE_POOL_TIMEOUT_MS"] = "100"
    Sqlx::Database.configure(ENV["PG_URL"].to_s, pool_size: 1)
  end

  def assert_equal(expected, actual, msg = nil)
    raise(msg || "expected #{expected.inspect}, got #{actual.inspect}") unless expected == actual
  end

  # While one lease holds the only connection, a second checkout fails with
  # `Sqlx::ConnectionTimeout` after the 100 ms budget.
  def test_checkout_timeout_raises
    held = [false]
    holder = Thread.new do
      Sqlx::Database.with_connection do
        Sqlx::Base.rows_by_sql("SELECT 1 AS one", [])
        held[0] = true
        sleep 0.5
      end
    end
    i = 0
    while !held[0] && i < 200
      sleep 0.01
      i += 1
    end

    began = Time.now
    raised = nil
    begin
      Sqlx::Database.with_connection do
        Sqlx::Base.rows_by_sql("SELECT 1 AS one", [])
      end
    rescue => e
      raised = e
    end
    elapsed = Time.now - began

    assert_equal "Sqlx::ConnectionTimeout", raised.class.to_s
    assert_equal true, elapsed < 1.0
    holder.join
  end

  # A scope that never touches the database must not wait for a pooled
  # connection, even when the only one is leased. The holder materializes its
  # lease; the no-database scope returns immediately instead of timing out.
  def test_a_no_database_scope_does_not_wait_for_a_connection
    held = [false]
    holder = Thread.new do
      Sqlx::Database.with_connection do
        Sqlx::Base.rows_by_sql("SELECT 1 AS one", [])
        held[0] = true
        sleep 0.4
      end
    end
    i = 0
    while !held[0] && i < 200
      sleep 0.01
      i += 1
    end

    started = Time.now
    Sqlx::Database.with_connection do
    end
    elapsed = Time.now - started
    holder.join

    assert_equal true, elapsed < 0.2
  end
end

FixtureRunner.run(PgPoolTimeoutTest, [
  "test_checkout_timeout_raises",
  "test_a_no_database_scope_does_not_wait_for_a_connection"
])
