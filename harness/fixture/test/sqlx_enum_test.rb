require_relative "test_helper"
require_relative "harness_runner"
require_relative "test_database"

# Sqlx::Base.enum (core) — a hand-written enum
# declaration validates once at load, answers label and value both
# ways from one source, and fails loud on the shapes that would alias
# silently. The bound writer (Enum#writer) rides here too:
# write is the declaration's counterpart, not a separate surface. setup owns
# a fresh table per case for the standard-shape walk.
class EnumTest < TestBase
  def setup
    TestDatabase.configure!("sqlx_enum")
    TestDatabase.drop_tables!("things")
    TestDatabase.exec("CREATE TABLE things (id INTEGER PRIMARY KEY, status INTEGER NOT NULL, updated_at DATETIME)")
    TestDatabase.exec("INSERT INTO things (status) VALUES (0), (1)")
  end

  def assert_equal(expected, actual, msg = nil)
    raise(msg || "expected #{expected.inspect}, got #{actual.inspect}") unless expected == actual
  end

  def cell(id, col)
    rows = Sqlx::Base.rows_by_sql("SELECT #{col} FROM things WHERE id = ?", [id])
    rows.empty? ? nil : rows[0][col]
  end

  def count_things
    rows = Sqlx::Base.rows_by_sql("SELECT COUNT(*) AS total FROM things")
    rows[0]["total"].to_i
  end

  # Declaration round trip: stored value → label and label → stored
  # value answer from the same declaration, in declaration order.
  def test_declaration_round_trip
    decl = Sqlx::Base.enum(trialing: 0, active: 1)
    assert_equal "trialing", decl.label(0)
    assert_equal 1, decl.value("active")
    assert_equal 0, decl.value(:trialing)
  end

  # A stored value no label names answers nil.
  def test_label_unknown_is_nil
    decl = Sqlx::Base.enum(active: 1)
    assert_equal nil, decl.label(7)
  end

  # An unknown name raises — not a to_i fallback that would read as
  # the first slot.
  def test_value_unknown_raises
    begin
      Sqlx::Base.enum(active: 1).value("bogus")
    rescue ArgumentError
      return
    end
    raise "expected ArgumentError from Enum#value"
  end

  # The stored-value spelling ("1") and the Symbol label both read
  # the same slot — the spellings the forms layer sends.
  def test_value_accepts_spellings
    decl = Sqlx::Base.enum(active: 1)
    assert_equal 1, decl.value("1")
    assert_equal 1, decl.value(:active)
  end

  # label? is the predicate form: a matching slot answers true, a
  # different slot or an unknown raw answers false, and the label
  # half stays strict so a declaration rename cannot make every
  # predicate answer false forever.
  def test_label_predicate
    decl = Sqlx::Base.enum(trialing: 0, active: 1)
    assert_equal true, decl.label?(0, :trialing)
    assert_equal true, decl.label?(1, "active")
    assert_equal false, decl.label?(1, :trialing)
    assert_equal false, decl.label?(7, :trialing)
  end

  # A label the declaration no longer carries raises at the first
  # predicate call — the loud edge the strict label half exists for.
  def test_label_predicate_unknown_label_raises
    begin
      Sqlx::Base.enum(active: 1).label?(1, :draft)
    rescue ArgumentError
      return
    end
    raise "expected ArgumentError from Enum#label?"
  end

  # Load-time loudness: the four shapes that would drift or alias
  # silently if the declaration were two parallel constants.
  def test_declaration_rejects_bad_shapes
    bad = [
      {},
      { "active" => 1 },
      { active: "1" },
      { active: 1, also_active: 1 }
    ]
    i = 0
    while i < bad.length
      begin
        Sqlx::Base.enum(bad[i])
      rescue ArgumentError
        i += 1
        next
      end
      raise "expected ArgumentError for declaration #{i}"
    end
  end

  # The standard shape end to end: declaration → reader → predicate →
  # bang writer through the declaration's `writer` factory — the
  # writer stores the label's value and stamps updated_at.
  def test_standard_shape_walk
    assert_equal "active", EnumShapeModel.status_label(2)
    assert_equal true, EnumShapeModel.active?(2)
    assert_equal false, EnumShapeModel.active?(1)
    assert_equal nil, cell(1, "updated_at")
    EnumShapeModel.pause!(1)
    assert_equal "paused", EnumShapeModel.status_label(1)
    assert_equal false, cell(1, "updated_at").nil?
  end

  # The writer factory lives on the declaration, so the call site
  # reads from the same STATUS receiver the readers use — no separate
  # factory, no declaration passed back in.
  def test_enum_writer_from_declaration
    assert_equal true, EnumShapeModel::STATUS.writer(
      table: "things", column: "status"
    ).is_a?(Sqlx::EnumWriter)
    EnumShapeModel.unpause!(2)
    assert_equal "trialing", EnumShapeModel.status_label(2)
  end

  # The writer answers nil: the bang promises the attempt, not the
  # rows a RETURNING statement would carry — its UPDATE returns none.
  def test_enum_writer_answers_nil
    assert_equal nil, EnumShapeModel::STATUS.writer(
      table: "things", column: "status"
    ).write!(1, :paused)
  end

  # An unknown label raises through the bound declaration before any
  # SQL runs — a redeclared enum cannot write a stale slot.
  def test_enum_writer_unknown_label_raises
    begin
      EnumShapeModel::STATUS.writer(
        table: "things", column: "status"
      ).write!(1, :bogus)
    rescue ArgumentError
      return
    end
    raise "expected ArgumentError from EnumWriter#write!"
  end

  # A row the id does not match is a silent no-op: the bang promises
  # the write attempt, not that a row existed (parity with the
  # per-model helpers this replaces).
  def test_enum_writer_missing_row_silent
    assert_equal 2, count_things
    EnumShapeModel.pause!(99)
    assert_equal 2, count_things
    assert_equal 0, Sqlx::Database.changes
  end
end

# The standard-shape model: the declaration owns the mapping and
# the writer factory, and each member is the one-liner the
# `enum` @example spells out.
class EnumShapeModel < Sqlx::Base
  STATUS = enum(trialing: 0, active: 1, paused: 2)

  def self.from_row(row)
    row["status"]
  end

  def self.status_label(id)
    STATUS.label(one_by_sql("SELECT status FROM things WHERE id = ?", [id]))
  end

  def self.active?(id)
    status_label(id) == "active"
  end

  def self.pause!(id)
    STATUS.writer(table: "things", column: "status").write!(id, :paused)
  end

  def self.unpause!(id)
    STATUS.writer(table: "things", column: "status").write!(id, :trialing)
  end
end

FixtureRunner.run(EnumTest, [
  "test_declaration_round_trip",
  "test_label_unknown_is_nil",
  "test_value_unknown_raises",
  "test_value_accepts_spellings",
  "test_label_predicate",
  "test_label_predicate_unknown_label_raises",
  "test_declaration_rejects_bad_shapes",
  "test_standard_shape_walk",
  "test_enum_writer_from_declaration",
  "test_enum_writer_answers_nil",
  "test_enum_writer_unknown_label_raises",
  "test_enum_writer_missing_row_silent"
])
