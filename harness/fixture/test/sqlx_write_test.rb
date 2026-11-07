require_relative "test_helper"
require_relative "harness_runner"
require_relative "test_database"

# Sqlx::Base.write (core spike) — parameterized
# writes take raw Ruby values and the adapter renders each by its runtime
# type, so app code never inlines literals. setup owns a fresh table pair
# per case. Reads assert per column (no mixed-type array
# leaves the core — that shape is the typed-array wall, not this path).
class WriteTest < TestBase
  def setup
    TestDatabase.configure!("sqlx_write")
    TestDatabase.drop_tables!("w", "w_uniq")
    TestDatabase.exec("CREATE TABLE w (id INTEGER PRIMARY KEY, name TEXT NOT NULL, nick TEXT, flag INTEGER NOT NULL DEFAULT 0, score REAL, at DATETIME)")
    TestDatabase.exec("CREATE TABLE w_uniq (id INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE)")
  end

  def assert_equal(expected, actual, msg = nil)
    raise(msg || "expected #{expected.inspect}, got #{actual.inspect}") unless expected == actual
  end

  def cell(id, col)
    rows = Sqlx::Base.rows_by_sql("SELECT #{col} FROM w WHERE id = ?", [id])
    rows.empty? ? nil : rows[0][col]
  end

  def count_where(cond)
    rows = Sqlx::Base.rows_by_sql("SELECT COUNT(*) AS total FROM w WHERE #{cond}")
    rows[0]["total"].to_i
  end

  # Every adapter type binds and reads back: quote-carrying text, nil,
  # bool, float, and Time in the runtime's stored form.
  def test_insert_binds_all_types
    at = Time.utc(2024, 1, 2, 3, 4, 5, 6)
    Sqlx::Base.write("INSERT INTO w (name, nick, flag, score, at) VALUES (?, ?, ?, ?, ?)", [ "o'brien", nil, true, 1.5, at ])
    id = Sqlx::Database.last_insert_rowid
    assert_equal "o'brien", cell(id, "name")
    assert_equal nil, cell(id, "nick")
    assert_equal 1, cell(id, "flag")
    assert_equal 1.5, cell(id, "score")
    assert_equal at, cell(id, "at").to_time
  end

  # UPDATE carries binds the same way; nil rebinds a column to NULL.
  def test_update_with_binds
    Sqlx::Base.write("INSERT INTO w (name, nick, flag) VALUES (?, ?, ?)", [ "alpha", "al", false ])
    id = Sqlx::Database.last_insert_rowid
    changed = Sqlx::Database.exec_write("UPDATE w SET nick = ?, flag = ? WHERE id = ?", [ nil, true, id ])["count"]
    assert_equal 1, changed
    assert_equal nil, cell(id, "nick")
    assert_equal 1, cell(id, "flag")
  end

  # DELETE binds its key; the row is gone afterward.
  def test_delete_with_bind
    Sqlx::Base.write("INSERT INTO w (name) VALUES (?)", [ "doomed" ])
    id = Sqlx::Database.last_insert_rowid
    changed = Sqlx::Database.exec_write("DELETE FROM w WHERE id = ?", [ id ])["count"]
    assert_equal 1, changed
    assert_equal 0, count_where("id = #{id}")
  end

  # A write with no placeholders still executes (and never replays).
  def test_zero_placeholder_write
    Sqlx::Base.write("INSERT INTO w (name) VALUES ('a')", [])
    Sqlx::Base.write("INSERT INTO w (name) VALUES ('b')", [])
    changed = Sqlx::Database.exec_write("UPDATE w SET flag = 7", [])["count"]
    assert_equal 2, changed
    assert_equal 2, count_where("flag = 7")
  end

  # The write answers what the statement returned: nothing for a
  # statement that returns nothing, one row per changed row for a
  # RETURNING statement.
  def test_write_answers_the_returned_rows
    assert_equal 0, Sqlx::Base.write("INSERT INTO w (name) VALUES (?)", [ "counted" ]).length
    Sqlx::Base.write("INSERT INTO w (name) VALUES (?)", [ "returned" ])
    id = Sqlx::Database.last_insert_rowid
    rows = Sqlx::Base.write("UPDATE w SET flag = 1 WHERE id = ? RETURNING id, name", [ id ])
    assert_equal 1, rows.length
    assert_equal id, rows[0]["id"]
    assert_equal "returned", rows[0]["name"]
  end

  # The adapter answers how many rows a statement changed — that count
  # belongs to the model layer, which asks the adapter for it.
  def test_the_adapter_answers_the_changed_row_count
    assert_equal 1, Sqlx::Database.exec_write("INSERT INTO w (name) VALUES (?)", [ "counted" ])["count"]
    assert_equal 1, Sqlx::Database.exec_write("INSERT INTO w_uniq (name) VALUES (?) ON CONFLICT DO NOTHING", [ "dup" ])["count"]
    assert_equal 0, Sqlx::Database.exec_write("INSERT INTO w_uniq (name) VALUES (?) ON CONFLICT DO NOTHING", [ "dup" ])["count"]
    assert_equal 0, Sqlx::Database.exec_write("UPDATE w SET nick = ? WHERE id = ?", [ "x", 99999 ])["count"]
  end

  # A statement that takes no values needs no value list — and a
  # value that does not fit a placeholder is loud, not a quiet NULL.
  def test_write_binds_every_value_and_counts_the_placeholders
    Sqlx::Base.write("INSERT INTO w (name) VALUES ('plain')")
    assert_equal 1, count_where("name = 'plain'")
    Sqlx::Base.write("INSERT INTO w (name) VALUES (?)", [ "bound" ])
    assert_equal 1, count_where("name = 'bound'")
    begin
      Sqlx::Base.write("INSERT INTO w (name, nick) VALUES (?, ?)", [ "one" ])
    rescue ArgumentError => e
      raise "unexpected message: #{e.message}" unless e.message.include?("placeholders")
      return
    end
    raise "expected a value/placeholder mismatch to be loud"
  end

  # The placeholder count is an internal helper — private on purpose, so
  # a call from outside is refused rather than answered.
  def test_placeholder_count_is_private
    begin
      Sqlx::Base.placeholder_count("SELECT 1")
    rescue NoMethodError
      return
    end
    raise "expected the placeholder count to be private"
  end

  # The value checker is private as well — the public entries are the
  # surface, not the check behind them.
  def test_values_for_placeholders_is_private
    begin
      Sqlx::Base.values_for_placeholders("SELECT 1", nil)
    rescue NoMethodError
      return
    end
    raise "expected the value checker to be private"
  end

  # A write that returns no rows answers an empty list.
  def test_write_answers_an_empty_list
    rows = Sqlx::Base.write("UPDATE w SET flag = 1 WHERE id = ? RETURNING id", [ 99999 ])
    assert_equal 0, rows.length
  end

  # A statement that returns rows changes rows too, so the adapter's
  # count says so as well — the two answers come from one execution.
  def test_the_adapter_counts_a_row_returning_statement
    Sqlx::Base.write("INSERT INTO w (name) VALUES (?)", [ "returned" ])
    id = Sqlx::Database.last_insert_rowid
    result = Sqlx::Database.exec_write("UPDATE w SET flag = 1 WHERE id = ? RETURNING id", [ id ])
    assert_equal 1, result["count"]
    assert_equal 1, result["rows"].length
  end

  # A parameterized write invalidates the request query cache, the
  # same rule `exec` follows: a count taken before the write must not
  # survive it. The lease brackets the cache.
  def test_write_invalidates_query_cache
    Sqlx::Base.write("INSERT INTO w (name) VALUES (?)", [ "first" ])
    Sqlx::Database.with_connection do
      before = count_where("1 = 1")
      Sqlx::Base.write("INSERT INTO w (name) VALUES (?)", [ "second" ])
      after = count_where("1 = 1")
      assert_equal before + 1, after
    end
  end

  # Inherited dispatch: models call the write through their own
  # constant, the same shape cross-model readers already use.
  def test_write_via_subclass
    SqlxWriteModel.write("INSERT INTO w (name) VALUES (?)", [ "sub" ])
    assert_equal 1, count_where("name = 'sub'")
  end

  # A UNIQUE violation surfaces as RecordNotUnique on the
  # parameterized path — the mapping the plain exec path already
  # carries, so a rescue written against one write path matches on
  # the other instead of leaking a driver RuntimeError.
  def test_unique_violation_raises_not_unique
    Sqlx::Base.write("INSERT INTO w_uniq (name) VALUES (?)", [ "dup" ])
    begin
      Sqlx::Base.write("INSERT INTO w_uniq (name) VALUES (?)", [ "dup" ])
    rescue Sqlx::RecordNotUnique
      return
    end
    raise "expected Sqlx::RecordNotUnique from the parameterized write"
  end
end

# The model for the inheritance check: only the write path
# through the model's own constant runs here, so hydration never
# fires — the body keeps the named-row shape.
class SqlxWriteModel < Sqlx::Base
  def self.from_row(row)
    row
  end
end

FixtureRunner.run(WriteTest, [
  "test_insert_binds_all_types",
  "test_update_with_binds",
  "test_delete_with_bind",
  "test_zero_placeholder_write",
  "test_write_answers_the_returned_rows",
  "test_the_adapter_answers_the_changed_row_count",
  "test_write_answers_an_empty_list",
  "test_placeholder_count_is_private",
  "test_values_for_placeholders_is_private",
  "test_write_binds_every_value_and_counts_the_placeholders",
  "test_the_adapter_counts_a_row_returning_statement",
  "test_write_invalidates_query_cache",
  "test_write_via_subclass",
  "test_unique_violation_raises_not_unique"
])
