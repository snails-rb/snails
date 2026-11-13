# Adapter contract — a condition the scaffold builds must be valid on the app's
# backend. This file runs in the sqlite demo and the pg canary, so a form
# that only one adapter compares fails before a consumer pins the core.
require_relative "../boot"

if Snails::Harness.file_selected?
  class AdapterTest < Snails::Harness::IntegrationTest
    # A boolean condition reaches the adapter as a literal. SQLite stores
    # the flags as 1/0; PostgreSQL stores a real boolean and rejects a
    # bare integer, so the adapter owns the spelling.
    test "where_clause compares a boolean the way the adapter spells it" do
      rows = Sqlx::Base.rows_by_sql(
        "SELECT one FROM (SELECT 1 AS one, true AS flag) AS flag_source WHERE " +
        Sqlx::Base.where_clause({ flag: true })
      )
      assert_equal 1, rows.length
      assert_equal 1, rows[0]["one"]
    end

    # A read with a value binds through the adapter's exec_read — the path
    # both adapters must implement, since the surface above it is
    # adapter-agnostic.
    test "a read binds its value on this adapter" do
      rows = Sqlx::Base.rows_by_sql("SELECT ? AS probe", [ "alpha" ])
      assert_equal 1, rows.length
      assert_equal "alpha", rows[0]["probe"]
    end
  end
end
