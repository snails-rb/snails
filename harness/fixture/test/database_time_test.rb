require_relative "test_helper"
require_relative "harness_runner"
require_relative "test_database"

# Sqlx read/quote (core) — a stored UTC datetime text read through the
# public raw-read entry parses to a Time; a NULL stays nil. A Time passed
# to `Sqlx.quote` renders as the same stored form. setup owns a fresh
# table per case.
class DatabaseTimeTest < TestBase
  def setup
    TestDatabase.configure!("database_time")
    TestDatabase.drop_tables!("stamps")
    TestDatabase.exec("CREATE TABLE stamps (id INTEGER PRIMARY KEY, at DATETIME)")
    TestDatabase.exec("INSERT INTO stamps (id, at) VALUES (1, '2024-01-02 03:04:05.000006')")
    TestDatabase.exec("INSERT INTO stamps (id, at) VALUES (2, NULL)")
  end

  def assert_equal(expected, actual, msg = nil)
    raise(msg || "expected #{expected.inspect}, got #{actual.inspect}") unless expected == actual
  end

  def stored_at(id)
    rows = Sqlx::Base.rows_by_sql("SELECT at FROM stamps WHERE id = ?", [id])
    rows.empty? ? nil : rows[0]["at"]
  end

  # The stored UTC text parses to the same instant, micros included.
  def test_stored_time_parses_text
    assert_equal Time.utc(2024, 1, 2, 3, 4, 5, 6), stored_at(1).to_time
  end

  # A NULL column reads back as nil, not a blank Time.
  def test_missing_time_is_nil
    assert_equal nil, stored_at(2)
  end

  # A Time renders as the runtime's stored form, quoted for inlining.
  def test_quote_time_literal
    assert_equal "'2024-01-02 03:04:05.000006'", Sqlx.quote(Time.utc(2024, 1, 2, 3, 4, 5, 6))
  end

  # The nullable literal renders nil as the SQL keyword NULL.
  def test_quote_nil_literal
    assert_equal "NULL", Sqlx.quote(nil)
  end
end

FixtureRunner.run(DatabaseTimeTest, [
  "test_stored_time_parses_text",
  "test_missing_time_is_nil",
  "test_quote_time_literal",
  "test_quote_nil_literal"
])
