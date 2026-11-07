# Per-case DB isolation — the core harness base empties the
# tables a case class declares (`tables`) before each fresh instance, so
# no case sees another case's writes. Runs on an in-file sqlite database;
# no gate environment required. The boot chain comes first because `Sqlx::Database`
# is the app's DB adapter (config/database.rb, required by boot).
require_relative "../boot"
require_relative "../snails-core/snails/harness"
require_relative "test_database"

TestDatabase.configure!("harness_isolation")
TestDatabase.drop_tables!("widgets")
TestDatabase.exec("CREATE TABLE IF NOT EXISTS widgets (id INTEGER PRIMARY KEY, name TEXT)")

class DatabaseIsolationTest < Snails::Harness::IntegrationTest
  # The declaration the app edits — these tables are emptied per case.
  def tables
    ["widgets"]
  end

  test "a case writes a row" do
    Sqlx::Database.exec("INSERT INTO widgets (id, name) VALUES (1, 'a')")
    rows = Sqlx::Base.rows_by_sql("SELECT id FROM widgets")
    assert_equal true, !rows.empty?
  end

  test "the next case starts empty" do
    rows = Sqlx::Base.rows_by_sql("SELECT id FROM widgets")
    assert_equal true, rows.empty?
  end
end
