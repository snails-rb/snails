require_relative "../test_helper"
require_relative "../harness_runner"

# The pg adapter's low-level helpers are private like the sqlite ones. The
# common file checks the public entries; this file checks the adapter helper
# names with real statement objects — the private call still raises, and the
# pg adapter's typed FFI path is not fed dummy zeroes.
class DatabasePrivateBoundaryTest < TestBase
  def test_database_low_level_helpers_are_private
    stmt = Sqlx::Database::PgStmt.new("SELECT 1")
    helpers = [
      "prepare",
      "step?",
      "column_int",
      "bind_int",
      "escape_string"
    ]
    helpers.each do |name|
      begin
        case name
        when "prepare"
          Sqlx::Database.prepare("SELECT 1")
        when "step?"
          Sqlx::Database.step?(stmt, "SELECT 1")
        when "column_int"
          Sqlx::Database.column_int(stmt, 0)
        when "bind_int"
          Sqlx::Database.bind_int(stmt, 1, 1)
        when "escape_string"
          Sqlx::Database.escape_string("x")
        end
      rescue NoMethodError
        next
      end
      raise "expected Sqlx::Database." + name + " to be private"
    end
  end
end

FixtureRunner.run(DatabasePrivateBoundaryTest, [
  "test_database_low_level_helpers_are_private"
])
