require_relative "test_helper"
require_relative "harness_runner"
require_relative "test_database"

# The adapter-independent half of the database private boundary: the
# connection reader is internal while the high-level entries stay callable.
# The low-level helper names are adapter-specific and live in each group.
class DatabasePublicBoundaryTest < TestBase
  def setup
    TestDatabase.configure!("database_public_boundary")
  end

  def assert_equal(expected, actual)
    raise("expected #{expected.inspect}, got #{actual.inspect}") unless expected == actual
  end

  # The adapter's connection reader is internal; an app calling it from
  # outside is refused.
  def test_database_connection_reader_is_private
    begin
      Sqlx::Database.current_conn
    rescue NoMethodError
      return
    end
    raise "expected Sqlx::Database.current_conn to be private"
  end

  # The high-level adapter entries stay callable: a read and a literal.
  def test_database_public_entries_stay_callable
    assert_equal [], Sqlx::Database.exec_read("SELECT 1 WHERE 1 = 0", [])
    assert_equal "'x'", Sqlx::Database.quote("x")
  end
end

FixtureRunner.run(DatabasePublicBoundaryTest, [
  "test_database_connection_reader_is_private",
  "test_database_public_entries_stay_callable"
])
