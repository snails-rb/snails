require_relative "test_helper"
require_relative "harness_runner"
require_relative "test_database"

# Sqlx::Base (core) — find_by_sql walks a caller-written
# SELECT through from_row: an implementing model gets one call per
# row, the bare base fails loud, and an empty result set collects
# into []. setup owns a fresh table set per case.
class SqlxTest < TestBase
  def setup
    TestDatabase.configure!("sqlx_base")
    TestDatabase.drop_tables!("samples", "ordered_items", "write_entries", "declared_samples", "plain_series", "json_samples")
    TestDatabase.exec("CREATE TABLE samples (id INTEGER PRIMARY KEY, name TEXT NOT NULL, tag TEXT)")
    TestDatabase.exec("INSERT INTO samples (name) VALUES ('alpha'), ('beta'), ('gamma')")
    # `order` is reserved: it needs quoting even in DDL, so this
    # table is the fixture for the core assembly's identifier
    # quoting.
    TestDatabase.exec('CREATE TABLE ordered_items (id INTEGER PRIMARY KEY, "order" TEXT NOT NULL)')
    TestDatabase.exec('INSERT INTO ordered_items ("order") VALUES (\'asc\')')
    # The write-entry fixture: both declared timestamp columns plus a
    # UNIQUE email, so create!/update! stamping and the UNIQUE check
    # ride on one declaration pair.
    TestDatabase.exec("CREATE TABLE write_entries (id INTEGER PRIMARY KEY, name TEXT NOT NULL, email TEXT UNIQUE, created_at DATETIME NOT NULL, updated_at DATETIME NOT NULL)")
    # The default-hydration fixture: no model method converts
    # anything — the declaration pair below is the whole contract.
    TestDatabase.exec("CREATE TABLE declared_samples (id INTEGER PRIMARY KEY, name TEXT NOT NULL, created_at DATETIME, seen_at DATETIME, flag INTEGER)")
    TestDatabase.exec("INSERT INTO declared_samples (name, created_at, seen_at, flag) VALUES ('alpha', '2026-10-05 17:32:02.443000', '2026-10-06 08:00:00.000000', 1), ('beta', NULL, NULL, 0)")
    # The upsert fixture: a primary-key-less table — the series key
    # is the identity — plus a second unique index an upsert
    # targeting the series key must NOT swallow (it stays loud).
    TestDatabase.exec("CREATE TABLE plain_series (ts TEXT NOT NULL, service TEXT NOT NULL, metric TEXT NOT NULL, kind TEXT, value REAL)")
    TestDatabase.exec("CREATE UNIQUE INDEX idx_plain_series_key ON plain_series (ts, service, metric)")
    TestDatabase.exec("CREATE UNIQUE INDEX idx_plain_series_metric ON plain_series (metric)")
    # The json fixture: a JSON-typed column pins the codec both ways —
    # stored text survives a re-read, and a scalar number comes back
    # equal.
    TestDatabase.exec("CREATE TABLE json_samples (id INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE, detail JSON)")
    SqlxCaptureModel.reset
    SqlxEachModel.reset
  end

  def assert_equal(expected, actual, msg = nil)
    raise(msg || "expected #{expected.inspect}, got #{actual.inspect}") unless expected == actual
  end

  # Loud failure: the base itself implements no from_row, so a bare
  # find_by_sql fails from the marker instead of returning junk rows.
  def test_base_from_row_loud
    begin
      Sqlx::Base.find_by_sql("SELECT name FROM samples")
    rescue NotImplementedError
      return
    end
    raise "expected NotImplementedError from Sqlx::Base.from_row"
  end

  # Mapping: the model's from_row runs once per row and its return
  # values collect into find_by_sql's result array, in order.
  def test_find_by_sql_maps_rows
    names = SqlxCaptureModel.find_by_sql("SELECT name FROM samples ORDER BY id")
    assert_equal ["alpha", "beta", "gamma"], names
    assert_equal 3, SqlxCaptureModel.calls
  end

  # The wrapper-free multi-row shape: a cross-class reader whose
  # sidecar .rbs declares Array[<Model>] compiles and hands back
  # mapped records — the specialized walk and the declaration agree,
  # so no per-model hydration wrapper exists for typing.
  def test_cross_class_typed_array
    rows = SqlxCrossReader.read_samples
    assert_equal 3, rows.length
    assert_equal ["alpha", "beta", "gamma"], rows.map(&:name)
  end

  # Empty result: no rows means from_row never runs and the caller
  # gets an empty array, not nil.
  def test_empty_result
    names = SqlxCaptureModel.find_by_sql("SELECT name FROM samples WHERE id > 100")
    assert_equal [], names
    assert_equal 0, SqlxCaptureModel.calls
  end

  # Existence is answered without hydrating a record (the counter stays 0).
  def test_exists_does_not_hydrate
    assert_equal true, SqlxCaptureModel.exists?({ name: "alpha" })
    assert_equal 0, SqlxCaptureModel.calls
  end

  # The raw-read half: a statement no model can stand behind hands back
  # name→value Hash rows, and it runs off the BASE — no
  # table_name/only_columns/from_row declaration needed, which is what
  # the model-hydrating trio demands.
  def test_rows_by_sql_returns_hash_rows
    rows = Sqlx::Base.rows_by_sql("SELECT name, id FROM samples ORDER BY id LIMIT 1")
    assert_equal 1, rows.length
    assert_equal "alpha", rows[0]["name"]
    assert_equal 1, rows[0]["id"]
  end

  # Aliased/computed columns stay dynamic — the Hash is the honest
  # shape, so an aggregate needs no model either.
  def test_rows_by_sql_aggregate
    row = Sqlx::Base.rows_by_sql("SELECT count(*) AS total FROM samples")[0]
    assert_equal 3, row["total"]
  end

  # Empty result: an array, not nil — the same "never nil" rule the
  # read trio follows.
  def test_rows_by_sql_empty_is_array
    assert_equal [], Sqlx::Base.rows_by_sql("SELECT name FROM samples WHERE id > 100")
  end

  # And it hydrates nothing — the capture counter stays at zero.
  def test_rows_by_sql_does_not_hydrate
    SqlxCaptureModel.rows_by_sql("SELECT name FROM samples ORDER BY id")
    assert_equal 0, SqlxCaptureModel.calls
  end

  # Undeclared model: the base owns no table/projection
  # declarations, so a bare find_by raises from the declaration
  # stub instead of answering nil.
  def test_find_by_base_loud
    begin
      Sqlx::Base.find_by({ name: "alpha" })
    rescue NotImplementedError
      return
    end
    raise "expected NotImplementedError from Sqlx::Base.find_by"
  end

  # The bang counterpart of the undeclared model: the base raises
  # NotImplementedError, not RecordNotFound — without declarations
  # neither miss path is reachable.
  def test_find_by_bang_base_loud
    begin
      Sqlx::Base.find_by!({ name: "alpha" })
    rescue NotImplementedError
      return
    end
    raise "expected NotImplementedError from Sqlx::Base.find_by!"
  end

  # The declaration pair is loud on the base: find_by splices both
  # values straight into the SELECT, so an undeclared table or
  # column list must raise before any SQL exists.
  def test_declaration_stubs_base_loud
    begin
      Sqlx::Base.table_name
    rescue NotImplementedError
    else
      raise "expected NotImplementedError from Sqlx::Base.table_name"
    end
    begin
      Sqlx::Base.only_columns
    rescue NotImplementedError
      return
    end
    raise "expected NotImplementedError from Sqlx::Base.only_columns"
  end

  # The projection is the one shared assembly: every declared column
  # qualified and quoted, ready to splice after SELECT — the same
  # spelling find_by and a model's raw walk both build.
  def test_projection_qualifies_and_quotes
    assert_equal '"samples"."name"', SqlxCaptureModel.projection
  end

  # The same assembly quotes a reserved-word column, so the list
  # parses even where the bare name would not (the `order` fixture
  # cannot even be a DDL column name unquoted).
  def test_projection_quotes_reserved_column
    assert_equal '"ordered_items"."order"', SqlxReservedModel.projection
  end

  # Undeclared model: the declaration stubs raise before any list
  # exists — never a nil spliced into the caller's SELECT.
  def test_projection_base_loud
    begin
      Sqlx::Base.projection
    rescue NotImplementedError
      return
    end
    raise "expected NotImplementedError from Sqlx::Base.projection"
  end

  # where_clause translates nil to IS NULL — the branch a
  # hand-rolled copy tends to drop, silently missing NULL rows.
  def test_where_clause_nil_is_null
    assert_equal "name IS NULL", SqlxCaptureModel.where_clause({ name: nil })
  end

  # The has-value side of the same question: the operator hash's null
  # test renders IS NOT NULL, rides the same AND chain as every other
  # condition, and reads as the SQL it produces.
  def test_where_clause_is_not_null
    assert_equal "tag IS NOT NULL",
                 SqlxCaptureModel.where_clause({ tag: { is_not: nil } })
    assert_equal "id = 2 AND tag IS NOT NULL",
                 SqlxCaptureModel.where_clause({ id: 2, tag: { is_not: nil } })
  end

  # Values never land in the SQL raw: integers through escape_int,
  # everything else through escape_string.
  def test_where_clause_escapes_values
    assert_equal "id = 3", SqlxCaptureModel.where_clause({ id: 3 })
    assert_equal "name = 'alpha'", SqlxCaptureModel.where_clause({ name: "alpha" })
  end

  # A boolean condition renders the adapter's spelling: SQLite stores
  # true/false as 1/0, while PostgreSQL's escape path quotes the value
  # ('1'/'0') so the integer column comparison stays valid.
  def test_where_clause_boolean_renders_the_adapter_spelling
    if TestDatabase.pg?
      assert_equal "flag = '1'", SqlxCaptureModel.where_clause({ flag: true })
      assert_equal "flag = '0'", SqlxCaptureModel.where_clause({ flag: false })
      assert_equal "flag IN ('1', '0')", SqlxCaptureModel.where_clause({ flag: [true, false] })
    else
      assert_equal "flag = 1", SqlxCaptureModel.where_clause({ flag: true })
      assert_equal "flag = 0", SqlxCaptureModel.where_clause({ flag: false })
      assert_equal "flag IN (1, 0)", SqlxCaptureModel.where_clause({ flag: [true, false] })
    end
  end

  # Multiple conditions join with AND in hash order.
  def test_where_clause_joins_with_and
    assert_equal "id = 2 AND name IS NULL",
                 SqlxCaptureModel.where_clause({ id: 2, name: nil })
  end

  # An empty hash has no clause to build — loud instead of an
  # empty fragment splicing into a WHERE-less SELECT.
  def test_where_clause_empty_loud
    begin
      SqlxCaptureModel.where_clause({})
    rescue ArgumentError
      return
    end
    raise "expected ArgumentError from Sqlx::Base.where_clause"
  end

  # An Array condition translates to membership: one escaped
  # element per entry, by the same per-type rules as equality —
  # integers through escape_int, everything else through
  # escape_string, mixed element types allowed element by element.
  def test_where_clause_array_membership
    assert_equal "id IN (1, 2, 3)", SqlxCaptureModel.where_clause({ id: [1, 2, 3] })
    assert_equal "name IN ('alpha', 'beta')",
                 SqlxCaptureModel.where_clause({ name: ["alpha", "beta"] })
    assert_equal "id IN (1, '2')", SqlxCaptureModel.where_clause({ id: [1, "2"] })
  end

  # Elements are data like any other value: the quote doubling runs
  # per element, never into the SQL raw.
  def test_where_clause_array_escapes_elements
    assert_equal "name IN ('it''s', 'a\\b')",
                 SqlxCaptureModel.where_clause({ name: ["it's", "a\\b"] })
  end

  # A Time condition renders in the runtime's stored form — the same
  # form the adapter binds a Time in. It used to render `Time#to_s`,
  # which is a different string: the condition then matched no stored
  # row and answered "nothing" instead of failing.
  def test_where_clause_time_renders_the_stored_form
    at = Time.utc(2026, 10, 5, 17, 32, 2, 443000)
    assert_equal "seen_at = '2026-10-05 17:32:02.443000'",
                 SqlxCaptureModel.where_clause({ seen_at: at })
  end

  # The clause matches the stored row: the literal and the stored form
  # are the same text, so the condition finds the row it names.
  def test_where_clause_time_matches_a_stored_row
    rows = Sqlx::Base.rows_by_sql("SELECT name FROM declared_samples WHERE " +
                                   Sqlx::Base.where_clause({ seen_at: Time.utc(2026, 10, 6, 8, 0, 0) }))
    assert_equal 1, rows.length
    assert_equal "alpha", rows[0]["name"]
  end

  # Membership joins the other predicates with AND, in hash order —
  # the clause body stays one flat AND chain.
  def test_where_clause_array_joins_with_and
    assert_equal "tag IS NULL AND id IN (2, 3)",
                 SqlxCaptureModel.where_clause({ tag: nil, id: [2, 3] })
  end

  # An empty array has no membership to build — IN () is not SQL,
  # so loud beats a driver syntax error or an invented translation.
  def test_where_clause_array_empty_loud
    begin
      SqlxCaptureModel.where_clause({ id: [] })
    rescue ArgumentError
      return
    end
    raise "expected ArgumentError from Sqlx::Base.where_clause"
  end

  # A nil element would half-answer as neither IS NULL nor a match
  # (IN (NULL, ...) is UNKNOWN for every row) — loud instead of a
  # translation that quietly drops the null rows.
  def test_where_clause_array_nil_element_loud
    begin
      SqlxCaptureModel.where_clause({ id: [1, nil] })
    rescue ArgumentError
      return
    end
    raise "expected ArgumentError from Sqlx::Base.where_clause"
  end

  # The operator-hash comparison: one predicate per whitelisted
  # operator, bounds rendered like equality — a Time in the stored
  # form, a number bare — and the chain stays one flat AND. This is
  # the range comparison the conditions contract can carry here: a
  # Range value with a Time bound cannot be built by this runtime
  # (spinel refuses it), and this form needs no Range object at all.
  def test_where_clause_comparison_predicates
    at = Time.utc(2026, 10, 6, 8, 0, 0)
    assert_equal "seen_at < '2026-10-06 08:00:00.000000'",
                 SqlxCaptureModel.where_clause({ seen_at: { lt: at } })
    assert_equal "id >= 1 AND id <= 2",
                 SqlxCaptureModel.where_clause({ id: { gte: 1, lte: 2 } })
    assert_equal "tag IS NULL AND seen_at >= '2026-10-06 08:00:00.000000'",
                 SqlxCaptureModel.where_clause({ tag: nil, seen_at: { gte: at } })
    # The bound type rides the same quote as equality: a number stays
    # bare, a String escapes and quotes, and a span of Strings is a
    # lexicographic range.
    assert_equal "id >= 1.5",
                 SqlxCaptureModel.where_clause({ id: { gte: 1.5 } })
    assert_equal "name >= 'be' AND name < 'c'",
                 SqlxCaptureModel.where_clause({ name: { gte: "be", lt: "c" } })
    assert_equal "name >= 'it''s'",
                 SqlxCaptureModel.where_clause({ name: { gte: "it's" } })
  end

  # The comparison rides the shared clause into a real statement: the
  # strict bound at the stored row's own timestamp excludes it (the
  # boundary is not less than itself), a cutoff a second later
  # includes it, and the inclusive bound matches at the boundary —
  # NULL stays out of every comparison.
  def test_where_clause_comparison_matches_stored_rows
    rows = Sqlx::Base.rows_by_sql("SELECT name FROM declared_samples WHERE " +
                                  Sqlx::Base.where_clause({ seen_at: { lt: Time.utc(2026, 10, 6, 8, 0, 0) } }))
    assert_equal 0, rows.length
    rows = Sqlx::Base.rows_by_sql("SELECT name FROM declared_samples WHERE " +
                                  Sqlx::Base.where_clause({ seen_at: { lt: Time.utc(2026, 10, 6, 8, 0, 1) } }))
    assert_equal 1, rows.length
    assert_equal "alpha", rows[0]["name"]
    rows = Sqlx::Base.rows_by_sql("SELECT name FROM declared_samples WHERE " +
                                  Sqlx::Base.where_clause({ seen_at: { gte: Time.utc(2026, 10, 6, 8, 0, 0) } }))
    assert_equal 1, rows.length
    assert_equal "alpha", rows[0]["name"]
    # A String bound compares lexicographically against the stored
    # text: everything from "beta" on (beta, gamma), strictly below
    # "beta" only alpha.
    rows = Sqlx::Base.rows_by_sql("SELECT name FROM samples WHERE " +
                                  Sqlx::Base.where_clause({ name: { gte: "beta" } }))
    assert_equal 2, rows.length
    rows = Sqlx::Base.rows_by_sql("SELECT name FROM samples WHERE " +
                                  Sqlx::Base.where_clause({ name: { lt: "beta" } }))
    assert_equal 1, rows.length
    assert_equal "alpha", rows[0]["name"]
  end

  # An operator outside the whitelist is a typo — loud at the entry,
  # not a comparison nobody meant rendered into the statement.
  def test_where_clause_comparison_unknown_operator_loud
    begin
      SqlxCaptureModel.where_clause({ id: { near: 3 } })
    rescue ArgumentError
      return
    end
    raise "expected ArgumentError from Sqlx::Base.where_clause"
  end

  # An empty operator hash has no predicate to build — the condition
  # would vanish from the clause silently, so loud like the empty
  # conditions hash.
  def test_where_clause_comparison_empty_hash_loud
    begin
      SqlxCaptureModel.where_clause({ id: {} })
    rescue ArgumentError
      return
    end
    raise "expected ArgumentError from Sqlx::Base.where_clause"
  end

  # A nil bound would render `< NULL` — a condition that matches
  # nothing — so loud instead of a quietly wrong clause.
  def test_where_clause_comparison_nil_bound_loud
    begin
      SqlxCaptureModel.where_clause({ id: { lt: nil } })
    rescue ArgumentError
      return
    end
    raise "expected ArgumentError from Sqlx::Base.where_clause"
  end

  # A structured bound (a nested typo like { lt: { lte: 1 } }) would
  # stringify into the comparison — loud before quote ever sees it.
  def test_where_clause_comparison_nested_bound_loud
    begin
      SqlxCaptureModel.where_clause({ id: { lt: { lte: 1 } } })
    rescue ArgumentError
      return
    end
    raise "expected ArgumentError from Sqlx::Base.where_clause"
  end

  # The null test is the only IS NOT form: SQL's IS NOT takes NULL
  # (and the boolean literals, out of this contract), so any other
  # bound is loud instead of rendering a comparison nobody meant.
  def test_where_clause_is_not_bound_loud
    begin
      SqlxCaptureModel.where_clause({ id: { is_not: 3 } })
    rescue ArgumentError
      return
    end
    raise "expected ArgumentError from where_clause with a non-nil is_not bound"
  end

  # A predicate belongs to a column, not to an IN list: an operator
  # hash as an element would stringify into a literal, so it is loud.
  def test_where_clause_array_operator_hash_loud
    begin
      SqlxCaptureModel.where_clause({ id: [1, { is_not: nil }] })
    rescue ArgumentError
      return
    end
    raise "expected ArgumentError from where_clause with an operator hash in an IN list"
  end

  # The empty hash reaches find_by the same way — the declaration
  # pair is present, so the clause guard is what must fire.
  def test_find_by_empty_loud
    begin
      SqlxCaptureModel.find_by({})
    rescue ArgumentError
      return
    end
    raise "expected ArgumentError from Sqlx::Base.find_by"
  end

  # The core shape end to end: the inherited find_by assembled from
  # the model's table/column declarations and where_clause answers
  # the row, or nil on a miss.
  def test_find_by_via_where_clause
    assert_equal "beta", SqlxCaptureModel.find_by({ id: 2 })
    assert_equal nil, SqlxCaptureModel.find_by({ id: 999 })
  end

  # find_by inherits the null test: the single-row lookup answers the
  # row whose column has a value, symmetric with the nil condition.
  def test_find_by_is_not_null_condition
    assert_equal "alpha", SqlxDeclaredModel.find_by({ seen_at: { is_not: nil } }).name
    assert_equal "beta", SqlxDeclaredModel.find_by({ seen_at: nil }).name
  end

  # A Time condition binds in the runtime's stored form, so the lookup
  # matches the row the stored text names.
  def test_find_by_time_condition_binds_to_the_stored_form
    assert_equal "alpha", SqlxDeclaredModel.find_by({ seen_at: Time.utc(2026, 10, 6, 8, 0, 0) }).name
  end

  # A value carrying a quote reaches the driver as a bound value, not
  # spliced SQL text, and the lookup still finds the row.
  def test_find_by_binds_a_quoted_string
    Sqlx::Database.exec("INSERT INTO samples (name) VALUES ('it''s')")
    assert_equal "it's", SqlxCaptureModel.find_by({ name: "it's" })
  end

  # Core quotes every identifier it assembles: `order` is a
  # reserved word that fails the SQL parse when unquoted (it cannot
  # even be a DDL column name without quotes), so the row can only
  # arrive through the quoted projection and table.
  def test_find_by_quotes_reserved_column
    assert_equal "asc", SqlxReservedModel.find_by({ id: 1 })
    assert_equal nil, SqlxReservedModel.find_by({ id: 999 })
  end

  # The bang counterpart raises RecordNotFound on the same miss — the two
  # miss paths stay distinct (nil vs raise).
  def test_find_by_bang_miss_raises
    begin
      SqlxCaptureModel.find_by!({ id: 999 })
    rescue Sqlx::RecordNotFound
      return
    end
    raise "expected Sqlx::RecordNotFound from SqlxCaptureModel.find_by!"
  end

  # The declared count: each model's table row total, straight from
  # COUNT(*) — no hydration and no cursor for the caller to walk.
  # The reserved-word model rides along so the quoting policy is
  # shared with find_by.
  def test_count_returns_row_count
    assert_equal 3, SqlxCaptureModel.count
    assert_equal 1, SqlxReservedModel.count
  end

  # Zero, not a miss: an emptied table still answers a number —
  # count has no exception path for "no rows".
  def test_count_empty_table_is_zero
    Sqlx::Database.exec("DELETE FROM samples")
    assert_equal 0, SqlxCaptureModel.count
  end

  # A read binds its values the way a write does — the value is not
  # spliced into the statement's text — and a value that does not fit
  # a placeholder is loud.
  def test_read_binds_its_values
    rows = Sqlx::Base.rows_by_sql("SELECT name FROM samples WHERE name = ?", [ "beta" ])
    assert_equal 1, rows.length
    assert_equal "beta", rows[0]["name"]
    begin
      Sqlx::Base.rows_by_sql("SELECT name FROM samples WHERE name = ? AND tag = ?", [ "beta" ])
    rescue ArgumentError => e
      raise "unexpected message: #{e.message}" unless e.message.include?("placeholders")
      return
    end
    raise "expected a value/placeholder mismatch to be loud"
  end

  # A step-time driver error is not an empty result: abs() of the
  # smallest 64-bit integer prepares fine and fails while stepping, so
  # the read path must raise instead of answering [].
  def test_step_error_is_not_an_empty_result
    begin
      Sqlx::Base.rows_by_sql("SELECT abs(-9223372036854775807 - 1)")
    rescue
      return
    end
    raise "expected a failing step to raise, not answer an empty result"
  end

  # A statement with a `?` and no value list is a missing bind, not a
  # NULL: the read entry checks even when the list is absent.
  def test_read_without_values_is_loud
    begin
      Sqlx::Base.rows_by_sql("SELECT name FROM samples WHERE name = ?")
    rescue ArgumentError => e
      raise "unexpected message: #{e.message}" unless e.message.include?("placeholders")
      return
    end
    raise "expected a missing value list to be loud"
  end

  # The hydrated entry delegates to the raw one, so the same missing
  # value list is loud before a row is mapped.
  def test_find_by_sql_without_values_is_loud
    begin
      SqlxCaptureModel.find_by_sql("SELECT name FROM samples WHERE name = ?")
    rescue ArgumentError => e
      raise "unexpected message: #{e.message}" unless e.message.include?("placeholders")
      return
    end
    raise "expected a missing value list to be loud through find_by_sql"
  end

  # The raw single-row counterpart takes the same value list as rows_by_sql.
  def test_row_by_sql_takes_values
    row = Sqlx::Base.row_by_sql("SELECT name, tag FROM samples WHERE name = ? ORDER BY id", [ "beta" ])
    assert_equal "beta", row["name"]
    assert_equal nil, Sqlx::Base.row_by_sql("SELECT name FROM samples WHERE name = ?", [ "nobody" ])
  end

  # The raw single-row form: the first row, keyed by column name, or
  # nil when the statement yields none. It is the raw counterpart of
  # the model-level single-row read — the same query without the
  # hydration.
  def test_row_by_sql_returns_the_first_row
    row = Sqlx::Base.row_by_sql("SELECT name, tag FROM samples ORDER BY id")
    assert_equal "alpha", row["name"]
    assert_equal nil, Sqlx::Base.row_by_sql("SELECT name FROM samples WHERE name = 'nobody'")
  end

  # A conditions hash counts the matching rows — the same conditions
  # contract find_by and delete_all! take (nil → IS NULL, an Array →
  # IN, anything else → equality).
  def test_count_with_conditions
    assert_equal 1, SqlxCaptureModel.count({ name: "beta" })
    assert_equal 0, SqlxCaptureModel.count({ name: "nobody" })
    assert_equal 3, SqlxCaptureModel.count({ tag: nil })
    assert_equal 3, SqlxCaptureModel.count({})
  end

  # The gap this closes at the model layer: counting rows whose
  # column has a value needs no raw aggregate — the null test is the
  # has-value side of the nil condition, and count inherits it.
  def test_count_is_not_null_condition
    assert_equal 2, SqlxDeclaredModel.count
    assert_equal 1, SqlxDeclaredModel.count({ seen_at: nil })
    assert_equal 1, SqlxDeclaredModel.count({ seen_at: { is_not: nil } })
  end

  # The missing declaration is loud the same way find_by's is: the
  # base has no table to count, so the stub raises before any SQL.
  def test_count_base_loud
    begin
      Sqlx::Base.count
    rescue NotImplementedError
      return
    end
    raise "expected NotImplementedError from Sqlx::Base.count"
  end

  # The id lookup answers the record for a matching row.
  def test_find_returns_record
    assert_equal "beta", SqlxCaptureModel.find(2)
  end

  # A miss raises — never nil — so a gone row becomes a 404 at the
  # call site instead of a nil that fails downstream.
  def test_find_miss_raises
    begin
      SqlxCaptureModel.find(999)
    rescue Sqlx::RecordNotFound
      return
    end
    raise "expected Sqlx::RecordNotFound from SqlxCaptureModel.find"
  end

  # The base has no table to look up: the declaration stub raises
  # before any SQL.
  def test_find_base_loud
    begin
      Sqlx::Base.find(1)
    rescue NotImplementedError
      return
    end
    raise "expected NotImplementedError from Sqlx::Base.find"
  end

  # The conditions-hash form answers true for a matching row and
  # false for a miss — find_by's rule without hydration.
  def test_exists_with_conditions
    assert_equal true, SqlxCaptureModel.exists?({ id: 2 })
    assert_equal false, SqlxCaptureModel.exists?({ id: 999 })
  end

  # The scalar form is the id shorthand — the shape the consumer
  # models' exists?(user_id) call sites already use.
  def test_exists_positional_id
    assert_equal true, SqlxCaptureModel.exists?(2)
    assert_equal false, SqlxCaptureModel.exists?(999)
  end

  # No argument (or an empty hash) asks whether the table has any
  # row at all: true with rows, false once they are gone.
  def test_exists_any_row
    assert_equal true, SqlxCaptureModel.exists?
    assert_equal true, SqlxCaptureModel.exists?({})
    Sqlx::Database.exec("DELETE FROM samples")
    assert_equal false, SqlxCaptureModel.exists?
    assert_equal false, SqlxCaptureModel.exists?({})
  end

  # nil answers false — there is no row named by nothing, and the
  # documented answer is no query at all for it.
  def test_exists_nil_is_false
    assert_equal false, SqlxCaptureModel.exists?(nil)
  end

  # The base has no table to probe: the declaration stub raises
  # before any SQL.
  def test_exists_base_loud
    begin
      Sqlx::Base.exists?
    rescue NotImplementedError
      return
    end
    raise "expected NotImplementedError from Sqlx::Base.exists?"
  end

  # Spec-only: the base declares all's signature and
  # semantics but owes no SQL — a bare call raises instead of
  # handing back an empty array that reads as "no rows".
  def test_all_base_loud
    begin
      Sqlx::Base.all
    rescue NotImplementedError
      return
    end
    raise "expected NotImplementedError from Sqlx::Base.all"
  end

  # The standard shape from the spec comment: the walk lives in
  # the model over its own projection, and every row arrives —
  # the recipe this spec pins does not rot.
  def test_all_via_recipe
    rows = SqlxCaptureModel.all
    assert_equal 3, rows.length
  end

  # The order option decides which matching row arrives: among two
  # rows sharing the condition, :desc hands back the higher id and
  # :asc the lower one.
  def test_find_by_order_desc_returns_last_match
    Sqlx::Database.exec("INSERT INTO samples (name, tag) VALUES ('beta', 'dup'), ('gamma', 'dup')")
    assert_equal "gamma", SqlxCaptureModel.find_by({ tag: "dup" }, order: :desc)
  end

  def test_find_by_order_asc_returns_first_match
    Sqlx::Database.exec("INSERT INTO samples (name, tag) VALUES ('beta', 'dup'), ('gamma', 'dup')")
    assert_equal "beta", SqlxCaptureModel.find_by({ tag: "dup" }, order: :asc)
  end

  # Order without conditions is a defined question: the table's
  # last row for :desc, its first row for :asc — while a bare
  # empty hash still raises (the find_by_empty case above).
  def test_find_by_empty_with_order_returns_table_edge
    assert_equal "gamma", SqlxCaptureModel.find_by({}, order: :desc)
    assert_equal "alpha", SqlxCaptureModel.find_by({}, order: :asc)
  end

  # A typo'd order fails loud before any SQL — it must never
  # silently fall back to an unordered row.
  def test_find_by_invalid_order_loud
    begin
      SqlxCaptureModel.find_by({ name: "alpha" }, order: :descending)
    rescue ArgumentError
      return
    end
    raise "expected ArgumentError from Sqlx::Base.find_by"
  end

  # The end-to-end shape membership exists for: a
  # filtered read through find_by — a row inside the set arrives,
  # a set that misses answers nil like any equality miss.
  def test_find_by_array_condition
    assert_equal "alpha", SqlxCaptureModel.find_by({ name: ["alpha", "zeta"] })
    assert_equal nil, SqlxCaptureModel.find_by({ name: ["zeta", "yap"] })
  end

  # Membership rides the order option too: among the rows whose
  # name is in the set, :desc picks the highest id and :asc the
  # lowest — the filtered latest-read that used to need
  # hand-written SQL.
  def test_find_by_array_condition_with_order
    Sqlx::Database.exec("INSERT INTO samples (name, tag) VALUES ('beta', 'dup'), ('gamma', 'dup')")
    assert_equal "gamma",
                 SqlxCaptureModel.find_by({ name: ["beta", "gamma"], tag: "dup" }, order: :desc)
    assert_equal "beta",
                 SqlxCaptureModel.find_by({ name: ["beta", "gamma"], tag: "dup" }, order: :asc)
  end

  # The multi-row counterpart end to end: the inherited fetch_many
  # assembles from the model's declarations, and a single matching
  # row still collects into an array — the shape never collapses to
  # a bare record.
  def test_fetch_many_single_match_is_array
    assert_equal ["beta"], SqlxCaptureModel.fetch_many({ id: 2 })
  end

  # No match answers [], not nil — and from_row never runs (the
  # counter stays at the reset setup left it).
  def test_fetch_many_empty_result
    assert_equal [], SqlxCaptureModel.fetch_many({ id: 999 })
    assert_equal 0, SqlxCaptureModel.calls
  end

  # Membership rides along: an Array condition filters the rows the
  # same way find_by's does — where_clause's rule is shared.
  def test_fetch_many_array_condition
    Sqlx::Database.exec("INSERT INTO samples (name, tag) VALUES ('beta', 'dup'), ('gamma', 'dup')")
    assert_equal ["beta", "gamma"],
                 SqlxCaptureModel.fetch_many({ name: ["beta", "gamma"], tag: "dup" }, order: :asc)
  end

  # The multi-row reader inherits the null test: only rows that have
  # the value come back, hydrated by the model's default.
  def test_fetch_many_is_not_null_condition
    rows = SqlxDeclaredModel.fetch_many({ seen_at: { is_not: nil } })
    assert_equal ["alpha"], rows.map(&:name)
  end

  # The order option sorts the returned rows by id: :desc is the
  # highest id first, :asc the lowest — the ordered association
  # reader that used to hand-write ORDER BY.
  def test_fetch_many_order_desc
    Sqlx::Database.exec("INSERT INTO samples (name, tag) VALUES ('beta', 'dup'), ('gamma', 'dup')")
    assert_equal ["gamma", "beta"], SqlxCaptureModel.fetch_many({ tag: "dup" }, order: :desc)
  end

  def test_fetch_many_order_asc
    Sqlx::Database.exec("INSERT INTO samples (name, tag) VALUES ('beta', 'dup'), ('gamma', 'dup')")
    assert_equal ["beta", "gamma"], SqlxCaptureModel.fetch_many({ tag: "dup" }, order: :asc)
  end

  # A typo'd order fails loud before any SQL — never silently
  # unordered rows (the find_by rule, multi-row edition).
  def test_fetch_many_invalid_order_loud
    begin
      SqlxCaptureModel.fetch_many({ tag: "dup" }, order: :descending)
    rescue ArgumentError
      return
    end
    raise "expected ArgumentError from Sqlx::Base.fetch_many"
  end

  # An empty conditions hash is the shape a broken condition builder
  # leaves behind — the whole table is the explicit nil, so an empty
  # hash raises instead of quietly widening the read to every row.
  def test_fetch_many_empty_loud
    begin
      SqlxCaptureModel.fetch_many({})
    rescue ArgumentError
      return
    end
    raise "expected ArgumentError from Sqlx::Base.fetch_many"
  end

  # nil conditions mean the whole table: every row comes back,
  # hydrated through the receiver's from_row — "every row" is the
  # explicit nil, never an empty hash.
  def test_fetch_many_nil_conditions_whole_table
    assert_equal ["alpha", "beta", "gamma"], SqlxCaptureModel.fetch_many(nil)
  end

  # The order option rides the whole-table read the same way it rides
  # a conditional one: nil is every row, sorted by id.
  def test_fetch_many_nil_conditions_order
    assert_equal ["gamma", "beta", "alpha"], SqlxCaptureModel.fetch_many(nil, order: :desc)
    assert_equal ["alpha", "beta", "gamma"], SqlxCaptureModel.fetch_many(nil, order: :asc)
  end

  # The declaration pair is loud the same way find_by's is: the
  # base has no table or column list to assemble from.
  def test_fetch_many_base_loud
    begin
      Sqlx::Base.fetch_many({ name: "alpha" })
    rescue NotImplementedError
      return
    end
    raise "expected NotImplementedError from Sqlx::Base.fetch_many"
  end

  # The typed multi-row shape through the core method: a cross-class
  # reader whose sidecar declares Array[<Model>] compiles over
  # fetch_many — the delegated walk still specializes on the
  # concrete receiver, so association readers stay wrapper-free.
  def test_fetch_many_cross_class_typed_array
    rows = SqlxCrossReader.read_by_name("alpha")
    assert_equal 1, rows.length
    assert_equal "alpha", rows[0].name
  end

  # A bounded read stops at the SQL window instead of collecting every
  # match: limit keeps the first N rows of the requested order.
  def test_fetch_many_limit_returns_the_first_n
    assert_equal ["alpha", "beta"], SqlxCaptureModel.fetch_many(nil, order: :asc, limit: 2)
  end

  # Limit without order is still a bounded read — which rows arrive is
  # implementation-defined, so the contract pins only the count.
  def test_fetch_many_limit_without_order_bounds_the_read
    assert_equal 2, SqlxCaptureModel.fetch_many(nil, limit: 2).length
  end

  # Offset walks one row at a time: the pages cover the table exactly
  # once, and the page past the end answers an empty array.
  def test_fetch_many_limit_offset_pages_without_repeats
    first = SqlxCaptureModel.fetch_many(nil, order: :asc, limit: 1, offset: 0)
    second = SqlxCaptureModel.fetch_many(nil, order: :asc, limit: 1, offset: 1)
    third = SqlxCaptureModel.fetch_many(nil, order: :asc, limit: 1, offset: 2)
    past = SqlxCaptureModel.fetch_many(nil, order: :asc, limit: 1, offset: 3)
    assert_equal ["alpha"], first
    assert_equal ["beta"], second
    assert_equal ["gamma"], third
    assert_equal [], past
  end

  # The conditions contract rides the window unchanged.
  def test_fetch_many_limit_with_conditions
    Sqlx::Database.exec("INSERT INTO samples (name, tag) VALUES ('beta', 'dup'), ('gamma', 'dup')")
    assert_equal ["gamma"], SqlxCaptureModel.fetch_many({ tag: "dup" }, order: :desc, limit: 1)
  end

  # A limit larger than the match set returns every match, and an
  # offset past the set returns none — both are window edges, not
  # errors.
  def test_fetch_many_limit_beyond_rows_returns_all
    assert_equal ["alpha", "beta", "gamma"], SqlxCaptureModel.fetch_many(nil, order: :asc, limit: 10)
    assert_equal [], SqlxCaptureModel.fetch_many(nil, order: :asc, limit: 2, offset: 10)
  end

  # A zero limit is a broken page size, not an empty page: it raises
  # before any SQL runs.
  def test_fetch_many_limit_zero_loud
    raised = false
    begin
      SqlxCaptureModel.fetch_many(nil, limit: 0)
    rescue ArgumentError
      raised = true
    end
    assert_equal true, raised
  end

  # A negative limit is rejected at the entry point.
  def test_fetch_many_negative_limit_loud
    raised = false
    begin
      SqlxCaptureModel.fetch_many(nil, limit: -1)
    rescue ArgumentError
      raised = true
    end
    assert_equal true, raised
  end

  # An offset without a limit would read the whole tail, so the entry
  # point rejects it before SQL runs.
  def test_fetch_many_offset_without_limit_loud
    raised = false
    begin
      SqlxCaptureModel.fetch_many(nil, order: :asc, offset: 1)
    rescue ArgumentError
      raised = true
    end
    assert_equal true, raised
  end

  # A page without a sort can repeat or skip rows under writes, so an
  # offset requires order.
  def test_fetch_many_offset_without_order_loud
    raised = false
    begin
      SqlxCaptureModel.fetch_many(nil, limit: 1, offset: 1)
    rescue ArgumentError
      raised = true
    end
    assert_equal true, raised
  end

  # A negative offset is rejected at the entry point.
  def test_fetch_many_negative_offset_loud
    raised = false
    begin
      SqlxCaptureModel.fetch_many(nil, order: :asc, limit: 1, offset: -1)
    rescue ArgumentError
      raised = true
    end
    assert_equal true, raised
  end

  # The walk visits every row once, in id order, through batches: two
  # rows then the remainder — no boundary repeat.
  def test_find_each_nil_conditions_walks_the_whole_table
    seen = []
    SqlxEachModel.find_each(nil, batch_size: 2) { |name| seen << name }
    assert_equal ["alpha", "beta", "gamma"], seen
    assert_equal 3, SqlxEachModel.calls
  end

  # The default batch size is a page, not a total cap: the whole
  # three-row table arrives and is still visited once.
  def test_find_each_default_batch_size_walks_the_whole_table
    seen = []
    SqlxEachModel.find_each(nil) { |name| seen << name }
    assert_equal ["alpha", "beta", "gamma"], seen
  end

  # The record path rides the same walk: a model's readers answer on
  # each yielded record, not on a raw row Hash.
  def test_find_each_yields_model_records
    names = []
    SqlxLoopModel.find_each(nil, batch_size: 2) { |row| names << row.name }
    assert_equal ["alpha", "beta", "gamma"], names
  end

  # One-row batches put every row on a boundary — still exactly once.
  def test_find_each_batch_size_one_hits_every_boundary
    seen = []
    SqlxEachModel.find_each(nil, batch_size: 1) { |name| seen << name }
    assert_equal ["alpha", "beta", "gamma"], seen
  end

  # A full final batch costs one empty follow-up query; the walk still
  # yields each row once.
  def test_find_each_exact_batch_size_does_not_repeat
    seen = []
    SqlxEachModel.find_each(nil, batch_size: 3) { |name| seen << name }
    assert_equal ["alpha", "beta", "gamma"], seen
  end

  # The conditions contract filters the walk and the cursor still
  # advances across the matching rows only.
  def test_find_each_conditions_filter_rows
    Sqlx::Database.exec("INSERT INTO samples (name, tag) VALUES ('beta', 'dup'), ('gamma', 'dup')")
    seen = []
    SqlxEachModel.find_each({ tag: "dup" }, batch_size: 1) { |name| seen << name }
    assert_equal ["beta", "gamma"], seen
  end

  # An id condition and the cursor combine with AND: the walk stays
  # inside the condition and never repeats the cursor row.
  def test_find_each_id_condition_combines_with_the_cursor
    seen = []
    SqlxEachModel.find_each({ id: [2, 3] }, batch_size: 1) { |name| seen << name }
    assert_equal ["beta", "gamma"], seen
  end

  # The cursor is keyset, not an offset: inserting a row before the
  # cursor between batches does not repeat an already-seen row (an
  # offset page would shift and yield alpha twice).
  def test_find_each_cursor_is_keyset_not_offset
    seen = []
    inserted = false
    SqlxEachModel.find_each(nil, batch_size: 1) do |name|
      seen << name
      unless inserted
        Sqlx::Database.exec("INSERT INTO samples (id, name) VALUES (0, 'zero')")
        inserted = true
      end
    end
    assert_equal ["alpha", "beta", "gamma"], seen
    assert_equal 3, SqlxEachModel.calls
  end

  # No matching row means no yield and no hydration.
  def test_find_each_empty_result_yields_nothing
    seen = []
    SqlxEachModel.find_each({ name: "zeta" }, batch_size: 2) { |name| seen << name }
    assert_equal [], seen
    assert_equal 0, SqlxEachModel.calls
  end

  # The whole table is spelled nil; an empty hash is the broken-builder
  # shape and raises before any SQL runs.
  def test_find_each_empty_conditions_loud
    raised = false
    begin
      SqlxEachModel.find_each({}) { |name| name }
    rescue ArgumentError
      raised = true
    end
    assert_equal true, raised
  end

  # A page size must be positive: zero and negative are rejected at the
  # entry point. A non-Integer is already a build-time type error, so
  # the harness pins the runtime half.
  def test_find_each_non_positive_batch_size_loud
    zero = false
    begin
      SqlxEachModel.find_each(nil, batch_size: 0) { |name| name }
    rescue ArgumentError
      zero = true
    end
    negative = false
    begin
      SqlxEachModel.find_each(nil, batch_size: -1) { |name| name }
    rescue ArgumentError
      negative = true
    end
    assert_equal true, zero
    assert_equal true, negative
  end

  # Without a block there is no work to do; returning an enumerator
  # would hide the missing callback, so the entry point raises.
  def test_find_each_requires_a_block
    raised = false
    begin
      SqlxEachModel.find_each(nil)
    rescue ArgumentError
      raised = true
    end
    assert_equal true, raised
  end

  # The cursor is read from the projection: a model that omits id
  # cannot walk (a silent stop after the first batch is the failure
  # this loud check prevents).
  def test_find_each_requires_id_projection
    raised = false
    begin
      SqlxCaptureModel.find_each(nil) { |name| name }
    rescue ArgumentError
      raised = true
    end
    assert_equal true, raised
  end

  # The base has no declarations, so the walk fails through the same
  # declaration stubs as the other read entries.
  def test_find_each_base_loud
    begin
      Sqlx::Base.find_each(nil) { |row| row }
    rescue NotImplementedError
      return
    end
    raise "expected NotImplementedError from Sqlx::Base.find_each"
  end

  # break in the block stops the walk at that row; the remaining rows
  # are never hydrated.
  def test_find_each_break_stops_the_walk
    seen = []
    SqlxEachModel.find_each(nil, batch_size: 1) do |name|
      seen << name
      break if name == "beta"
    end
    assert_equal ["alpha", "beta"], seen
    assert_equal 2, SqlxEachModel.calls
  end

  # Batching is real, not a full load followed by yields: at the first
  # yield only the first one-row batch has been hydrated.
  def test_find_each_hydrates_one_batch_at_a_time
    seen = []
    SqlxEachModel.find_each(nil, batch_size: 1) do |name|
      seen << name
      if seen.length == 1
        assert_equal 1, SqlxEachModel.calls
      end
    end
    assert_equal ["alpha", "beta", "gamma"], seen
    assert_equal 3, SqlxEachModel.calls
  end

  # The bulk walk yields whole batches: two rows then the final short
  # batch, so one block call can carry one bulk operation.
  def test_find_in_batches_yields_batch_arrays
    batches = []
    SqlxEachModel.find_in_batches(nil, batch_size: 2) { |rows| batches << rows }
    assert_equal 2, batches.length
    assert_equal ["alpha", "beta"], batches[0]
    assert_equal ["gamma"], batches[1]
  end

  # The default page size is a page, not a cap: the three-row table is
  # one batch.
  def test_find_in_batches_default_batch_size_is_one_batch
    batches = []
    SqlxEachModel.find_in_batches(nil) { |rows| batches << rows }
    assert_equal 1, batches.length
    assert_equal 3, batches[0].length
  end

  # A full final batch does not repeat: three rows in batches of three
  # arrive as one batch, then the empty follow-up stops the walk.
  def test_find_in_batches_exact_batch_size_does_not_repeat
    batches = []
    SqlxEachModel.find_in_batches(nil, batch_size: 3) { |rows| batches << rows }
    assert_equal 1, batches.length
    assert_equal ["alpha", "beta", "gamma"], batches[0]
  end

  # The conditions contract filters the batches, and the cursor still
  # advances across the matching rows only.
  def test_find_in_batches_conditions_filter_rows
    Sqlx::Database.exec("INSERT INTO samples (name, tag) VALUES ('beta', 'dup'), ('gamma', 'dup')")
    batches = []
    SqlxEachModel.find_in_batches({ tag: "dup" }, batch_size: 1) { |rows| batches << rows }
    assert_equal [["beta"], ["gamma"]], batches
  end

  # The model-record path works through the bulk walk the same way.
  def test_find_in_batches_yields_model_records
    batches = []
    SqlxLoopModel.find_in_batches(nil, batch_size: 2) { |rows| batches << rows }
    assert_equal 2, batches.length
    assert_equal ["alpha", "beta"], batches[0].map { |row| row.name }
    assert_equal ["gamma"], batches[1].map { |row| row.name }
  end

  # The cursor is keyset, not an offset: inserting a row before the
  # cursor between batches does not repeat an already-seen row.
  def test_find_in_batches_cursor_is_keyset_not_offset
    batches = []
    inserted = false
    SqlxEachModel.find_in_batches(nil, batch_size: 1) do |rows|
      batches << rows
      unless inserted
        Sqlx::Database.exec("INSERT INTO samples (id, name) VALUES (0, 'zero')")
        inserted = true
      end
    end
    assert_equal [["alpha"], ["beta"], ["gamma"]], batches
  end

  # One bulk operation per batch: the batch array's ids feed
  # update_all!, so the writes are one statement per batch, not one per
  # record.
  def test_find_in_batches_bulk_update_per_batch
    SqlxLoopModel.find_in_batches(nil, batch_size: 2) do |records|
      ids = records.map { |record| record.id }
      SqlxLoopModel.update_all!({ id: ids }, { tag: "seen" })
    end
    assert_equal ["alpha", "beta", "gamma"], SqlxCaptureModel.fetch_many({ tag: "seen" }, order: :asc)
  end

  # No matching row means no batch and no hydration.
  def test_find_in_batches_empty_result_yields_nothing
    batches = []
    SqlxEachModel.find_in_batches({ name: "zeta" }, batch_size: 2) { |rows| batches << rows }
    assert_equal [], batches
    assert_equal 0, SqlxEachModel.calls
  end

  # The whole table is spelled nil; an empty hash raises before SQL.
  def test_find_in_batches_empty_conditions_loud
    raised = false
    begin
      SqlxEachModel.find_in_batches({}) { |rows| rows }
    rescue ArgumentError
      raised = true
    end
    assert_equal true, raised
  end

  # A page size must be positive: zero and negative are rejected.
  def test_find_in_batches_non_positive_batch_size_loud
    zero = false
    begin
      SqlxEachModel.find_in_batches(nil, batch_size: 0) { |rows| rows }
    rescue ArgumentError
      zero = true
    end
    negative = false
    begin
      SqlxEachModel.find_in_batches(nil, batch_size: -1) { |rows| rows }
    rescue ArgumentError
      negative = true
    end
    assert_equal true, zero
    assert_equal true, negative
  end

  # Without a block there is no work to do; the entry point raises.
  def test_find_in_batches_requires_a_block
    raised = false
    begin
      SqlxEachModel.find_in_batches(nil)
    rescue ArgumentError
      raised = true
    end
    assert_equal true, raised
  end

  # The cursor is read from the projection: a model without id cannot
  # use the bulk walk.
  def test_find_in_batches_requires_id_projection
    raised = false
    begin
      SqlxCaptureModel.find_in_batches(nil) { |rows| rows }
    rescue ArgumentError
      raised = true
    end
    assert_equal true, raised
  end

  # The base has no declarations, so the bulk walk fails through the
  # same declaration stubs.
  def test_find_in_batches_base_loud
    begin
      Sqlx::Base.find_in_batches(nil) { |rows| rows }
    rescue NotImplementedError
      return
    end
    raise "expected NotImplementedError from Sqlx::Base.find_in_batches"
  end

  # break in the block stops the walk before the next batch query.
  def test_find_in_batches_break_stops_the_walk
    batches = []
    SqlxEachModel.find_in_batches(nil, batch_size: 1) do |rows|
      batches << rows
      break
    end
    assert_equal [["alpha"]], batches
    assert_equal 1, SqlxEachModel.calls
  end

  # The whole batch is hydrated before the block runs, but the next
  # batch is not: at the first yield only two of the three rows have
  # been hydrated.
  def test_find_in_batches_hydrates_one_batch_at_a_time
    batches = []
    SqlxEachModel.find_in_batches(nil, batch_size: 2) do |rows|
      batches << rows
      if batches.length == 1
        assert_equal 2, SqlxEachModel.calls
      end
    end
    assert_equal 2, batches.length
    assert_equal 3, SqlxEachModel.calls
  end

  # The hash-backed path end to end: the inherited find_by assembles
  # from the model's declarations and hydrates through from_row into
  # the generic initialize — the loop-generated readers answer with
  # no hand-written initialize or attr_reader anywhere in the model.
  def test_loop_find_by
    row = SqlxLoopModel.find_by({ id: 2 })
    assert_equal 2, row.id
    assert_equal "beta", row.name
  end

  # The multi-row shape rides the same path: fetch_many answers the
  # rows in the requested order, so an association reader needs no
  # hand-written accessors either.
  def test_loop_fetch_many
    rows = SqlxLoopModel.fetch_many({ id: [1, 2] }, order: :desc)
    assert_equal ["beta", "alpha"], rows.map(&:name)
  end

  # The declaration pair stays owned by the model as literal defs —
  # the accessor path adds no metaprogramming over declarations.
  def test_loop_declarations
    assert_equal "samples", SqlxLoopModel.table_name
    assert_equal [:id, :name], SqlxLoopModel.only_columns
  end

  # The counter shape rides the same path: the declared table's row
  # total comes back without hydration, same as the plain path.
  def test_loop_count
    assert_equal 3, SqlxLoopModel.count
  end

  # The typed shape on this path: a cross-class reader whose sidecar
  # declares Array[SqlxLoopModel] compiles, so loop-generated
  # readers type through the sidecar like hand-written ones do.
  def test_loop_cross_class_typed_array
    rows = SqlxCrossReader.read_loop_rows
    assert_equal 2, rows.length
    assert_equal "alpha", rows[0].name
  end

  # Entry validation: a keyword that is not a declared column
  # raises at initialize — a typo is loud here, never a silent nil
  # from the accessor later.
  def test_loop_unknown_attribute_loud
    begin
      SqlxLoopModel.new(id: 1, naem: "typo")
    rescue ArgumentError
      return
    end
    raise "expected ArgumentError from SqlxLoopModel#initialize"
  end

  # Partial construction: a column left out reads as nil — an
  # unselected column and a NULL value are the same answer.
  def test_loop_missing_attribute_is_nil
    row = SqlxLoopModel.new(id: 4)
    assert_equal 4, row.id
    assert_equal nil, row.name
  end

  # The default hydration: with no from_row on the model, the
  # inherited walk copies every projected column and converts the
  # built-in stamps plus the declared exceptions — the stored-TEXT
  # datetime becomes a Time (created_at with no declaration at all)
  # and the stored 1/0 becomes a boolean, NULL staying nil.
  def test_default_hydration_converts_declared_columns
    alpha = SqlxDeclaredModel.find(1)
    assert_equal "alpha", alpha.name
    assert_equal true, alpha.created_at.is_a?(Time)
    assert_equal Time.utc(2026, 10, 5, 17, 32, 2, 443000), alpha.created_at
    assert_equal Time.utc(2026, 10, 6, 8, 0, 0), alpha.seen_at
    assert_equal true, alpha.flag

    beta = SqlxDeclaredModel.find(2)
    assert_equal nil, beta.created_at
    assert_equal nil, beta.seen_at
    assert_equal false, beta.flag
  end

  # The stamp pair is legal even where the table has no such column:
  # the default hydration passes the absent stamps by, so a model
  # over a stamp-less table hydrates without a declaration error.
  def test_default_stamps_skip_when_table_lacks_them
    rec = SqlxStamplessModel.find(1)
    assert_equal "alpha", rec.name
  end

  # A declared exception outside only_columns is loud — only the
  # built-in stamps are exempt — so a typo fails at the declaration
  # instead of staying raw silently.
  def test_default_hydration_unknown_declared_column_loud
    begin
      SqlxBadDeclaredModel.find(1)
    rescue ArgumentError
      return
    end
    raise "expected ArgumentError from the unknown declared column"
  end

  # The named-row shape end to end: hydration keys off column
  # names, so a SELECT whose column order differs from only_columns
  # still lands every value on its own attribute — the positional
  # read this shape replaced could only stay correct by hand.
  def test_hydration_is_column_order_independent
    rows = SqlxLoopModel.find_by_sql("SELECT name, id FROM samples WHERE id = 2")
    row = rows[0]
    assert_equal 2, row.id
    assert_equal "beta", row.name
  end

  # NULL arrives as nil for every column type — the type-specific
  # `_opt` readers were a positional artifact and are gone.
  def test_null_column_reads_as_nil
    SqlxWriteEntryModel.create!({ name: "nullable" })
    row = SqlxWriteEntryModel.find_by({ name: "nullable" })
    assert_equal nil, row.email
  end

  # create! end to end: the attrs keys become the INSERT columns, the
  # declared timestamps fill themselves with ONE shared value, and the
  # call hands back the persisted row re-read by its id.
  def test_create_returns_persisted_record
    rec = SqlxWriteEntryModel.create!({ name: "alpha", email: "a@example.com" })
    assert_equal "alpha", rec.name
    assert_equal "a@example.com", rec.email
    assert_equal true, rec.id > 0
    assert_equal false, rec.created_at.nil?
    assert_equal false, rec.updated_at.nil?
    assert_equal rec.created_at, rec.updated_at
  end

  # An explicit id is the id the caller wrote: the INSERT's RETURNING row
  # answers it, so a session last-insert value cannot answer for another
  # row (or fall out of the sequence entirely).
  def test_create_with_explicit_id_returns_that_row
    rec = SqlxWriteEntryModel.create!({ id: 4242, name: "explicit", email: "explicit@example.com" })
    assert_equal 4242, rec.id
    assert_equal "explicit", rec.name
  end

  # A timestamp the caller passes wins over the automatic stamp —
  # the caller's value, not the clock's.
  def test_create_caller_timestamp_wins
    rec = SqlxWriteEntryModel.create!({ name: "pin", email: "p@example.com", created_at: "2020-01-01 00:00:00", updated_at: "2020-01-01 00:00:00" })
    assert_equal Time.utc(2020, 1, 1), rec.created_at
    assert_equal Time.utc(2020, 1, 1), rec.updated_at
  end

  # Empty attrs: there is no row to insert and no columns to name —
  # loud instead of an INSERT with an empty column list.
  def test_create_empty_attrs_loud
    begin
      SqlxWriteEntryModel.create!({})
    rescue ArgumentError
      return
    end
    raise "expected ArgumentError from Sqlx::Base.create!"
  end

  # A UNIQUE violation raises RecordNotUnique — the bang rule:
  # a schema constraint is the validation this layer has, and the
  # exception reaches the caller instead of a row-less success.
  def test_create_unique_violation_raises_not_unique
    SqlxWriteEntryModel.create!({ name: "first", email: "dup@example.com" })
    begin
      SqlxWriteEntryModel.create!({ name: "second", email: "dup@example.com" })
    rescue Sqlx::RecordNotUnique
      return
    end
    raise "expected Sqlx::RecordNotUnique from Sqlx::Base.create!"
  end

  # Undeclared model: the declaration stubs raise before any SQL.
  def test_create_base_loud
    begin
      Sqlx::Base.create!({ name: "x" })
    rescue NotImplementedError
      return
    end
    raise "expected NotImplementedError from Sqlx::Base.create!"
  end

  # update! end to end: the attrs rewrite the row, the declared
  # updated_at fills itself, created_at is never touched, and the
  # call hands back the re-read row.
  def test_update_returns_persisted_record
    rec = SqlxWriteEntryModel.create!({ name: "before", email: "u@example.com" })
    updated = SqlxWriteEntryModel.update!(rec.id, { name: "after" })
    assert_equal "after", updated.name
    assert_equal "u@example.com", updated.email
    assert_equal rec.created_at, updated.created_at
    assert_equal false, updated.updated_at.nil?
  end

  # The stamp is refresh, not passthrough: a stale updated_at is
  # replaced with the current db time on update!.
  def test_update_refreshes_updated_at
    rec = SqlxWriteEntryModel.create!({ name: "stale", email: "s@example.com", updated_at: "2020-01-01 00:00:00" })
    updated = SqlxWriteEntryModel.update!(rec.id, { name: "fresh" })
    assert_equal false, updated.updated_at == Time.utc(2020, 1, 1)
  end

  # A timestamp the caller passes wins over the automatic stamp on
  # update! too.
  def test_update_caller_timestamp_wins
    rec = SqlxWriteEntryModel.create!({ name: "any", email: "t@example.com" })
    updated = SqlxWriteEntryModel.update!(rec.id, { name: "pinned", updated_at: "2021-02-03 04:05:06" })
    assert_equal Time.utc(2021, 2, 3, 4, 5, 6), updated.updated_at
  end

  # An unknown id is loud: the 0-row UPDATE is silent, so the
  # re-read raises RecordNotFound instead of returning a record
  # that was never written.
  def test_update_unknown_id_raises
    begin
      SqlxWriteEntryModel.update!(999, { name: "ghost" })
    rescue Sqlx::RecordNotFound
      return
    end
    raise "expected Sqlx::RecordNotFound from Sqlx::Base.update!"
  end

  # Empty attrs: there is nothing to rewrite — a stamp-only write
  # belongs to a dedicated entry, not this one.
  def test_update_empty_attrs_loud
    begin
      SqlxWriteEntryModel.update!(1, {})
    rescue ArgumentError
      return
    end
    raise "expected ArgumentError from Sqlx::Base.update!"
  end

  # Undeclared model: the declaration stubs raise before any SQL.
  def test_update_base_loud
    begin
      Sqlx::Base.update!(1, { name: "x" })
    rescue NotImplementedError
      return
    end
    raise "expected NotImplementedError from Sqlx::Base.update!"
  end

  # update_all! end to end: every matching row changes, the return
  # is the affected-row count, and rows outside the conditions stay
  # where they were.
  def test_update_all_returns_affected_count
    SqlxWriteEntryModel.create!({ name: "a", email: "a@example.com" })
    SqlxWriteEntryModel.create!({ name: "b", email: "b@example.com" })
    SqlxWriteEntryModel.create!({ name: "c", email: "c@example.com" })
    changed = SqlxWriteEntryModel.update_all!({ name: ["a", "b"] }, { name: "archived" })
    assert_equal 2, changed
    rows = Sqlx::Base.rows_by_sql("SELECT name FROM write_entries ORDER BY id")
    assert_equal 3, rows.length
    assert_equal "archived", rows[0]["name"]
    assert_equal "archived", rows[1]["name"]
    assert_equal "c", rows[2]["name"]
  end

  # The conditions contract carries the range comparison — the span
  # picks the rows on the same where_clause every reader uses, and
  # the boundary row stays out of the rewrite.
  def test_update_all_range_conditions
    changed = SqlxCaptureModel.update_all!({ id: { lt: 3 } }, { tag: "old" })
    assert_equal 2, changed
    rows = Sqlx::Base.rows_by_sql("SELECT tag FROM samples ORDER BY id")
    assert_equal "old", rows[0]["tag"]
    assert_equal "old", rows[1]["tag"]
    assert_equal nil, rows[2]["tag"]
  end

  # A caller-passed value is what lands — including a timestamp:
  # the binding contract is update!'s, so a Time (or its stored
  # spelling) is written exactly as given.
  def test_update_all_binds_caller_time
    rec = SqlxWriteEntryModel.create!({ name: "t", email: "t@example.com" })
    SqlxWriteEntryModel.update_all!({ id: rec.id }, { name: "pinned", updated_at: "2021-02-03 04:05:06" })
    rows = Sqlx::Base.rows_by_sql("SELECT name, updated_at FROM write_entries WHERE id = ?", [ rec.id ])
    assert_equal "pinned", rows[0]["name"]
    assert_equal "2021-02-03 04:05:06", rows[0]["updated_at"]
  end

  # No timestamp is stamped: rewriting a row leaves updated_at
  # exactly as it was — the caller moves it when it wants it moved.
  def test_update_all_does_not_stamp
    SqlxWriteEntryModel.create!({ name: "n", email: "n@example.com", updated_at: "2021-02-03 04:05:06" })
    SqlxWriteEntryModel.update_all!({ name: "n" }, { name: "renamed" })
    rows = Sqlx::Base.rows_by_sql("SELECT name, updated_at FROM write_entries WHERE name = 'renamed'")
    assert_equal 1, rows.length
    assert_equal "2021-02-03 04:05:06", rows[0]["updated_at"]
  end

  # nil conditions mean the whole table: every row is rewritten and
  # the return is the full count — "every row" is the explicit nil,
  # never an empty hash.
  def test_update_all_nil_conditions_whole_table
    SqlxWriteEntryModel.create!({ name: "a", email: "a@example.com" })
    SqlxWriteEntryModel.create!({ name: "b", email: "b@example.com" })
    changed = SqlxWriteEntryModel.update_all!(nil, { name: "bulk" })
    assert_equal 2, changed
    rows = Sqlx::Base.rows_by_sql("SELECT name FROM write_entries ORDER BY id")
    assert_equal 2, rows.length
    assert_equal "bulk", rows[0]["name"]
    assert_equal "bulk", rows[1]["name"]
  end

  # An empty conditions hash is the shape a broken condition builder
  # leaves behind — the whole table is the explicit nil, so an empty
  # hash raises instead of quietly widening the rewrite to every row.
  def test_update_all_empty_conditions_loud
    begin
      SqlxCaptureModel.update_all!({}, { tag: "x" })
    rescue ArgumentError
      return
    end
    raise "expected ArgumentError from Sqlx::Base.update_all!"
  end

  # Empty attrs: there is nothing to rewrite — the same loud rule
  # as update!'s empty attrs.
  def test_update_all_empty_attrs_loud
    begin
      SqlxCaptureModel.update_all!({ id: 1 }, {})
    rescue ArgumentError
      return
    end
    raise "expected ArgumentError from Sqlx::Base.update_all!"
  end

  # An unknown column is loud from the driver — the attr key is
  # code, so a typo surfaces as the SQL error, never a quiet no-op.
  def test_update_all_unknown_column_loud
    begin
      SqlxCaptureModel.update_all!({ id: 1 }, { bogus: "x" })
    rescue RuntimeError
      return
    end
    raise "expected a driver error from Sqlx::Base.update_all!"
  end

  # Undeclared model: the declaration stub raises before any SQL.
  def test_update_all_base_loud
    begin
      Sqlx::Base.update_all!({ id: 1 }, { name: "x" })
    rescue NotImplementedError
      return
    end
    raise "expected NotImplementedError from Sqlx::Base.update_all!"
  end

  # upsert end to end on a table with no primary key: the first call
  # inserts, a re-upsert of the same series key rewrites only the
  # updatable columns, and the return is the row count each time.
  def test_upsert_all_writes_and_rewrites
    inserted = PlainSeries.upsert_all!([
      { ts: "2026-10-01 00:00:00", service: "web", metric: "cpu", kind: "gauge", value: 1.0 },
      { ts: "2026-10-02 00:00:00", service: "web", metric: "mem", kind: "gauge", value: 2.0 }
    ], unique_by: [ :ts, :service, :metric ])
    assert_equal 2, inserted
    rewritten = PlainSeries.upsert_all!([
      { ts: "2026-10-01 00:00:00", service: "web", metric: "cpu", kind: "delta", value: 9.5 }
    ], unique_by: [ :ts, :service, :metric ])
    assert_equal 1, rewritten
    rows = Sqlx::Base.rows_by_sql("SELECT ts, kind, value FROM plain_series ORDER BY ts")
    assert_equal 2, rows.length
    assert_equal "delta", rows[0]["kind"]
    assert_equal 9.5, rows[0]["value"]
    assert_equal "2026-10-02 00:00:00", rows[1]["ts"]
    assert_equal "gauge", rows[1]["kind"]
  end

  # A conflict on ANOTHER unique index is not this statement's
  # business — targeting the series key leaves the second index to
  # fail loud, so a wrong-row update can never hide behind the
  # upsert.
  def test_upsert_all_other_unique_index_raises
    PlainSeries.upsert_all!([ { ts: "2026-10-01 00:00:00", service: "web", metric: "cpu", kind: "gauge", value: 1.0 } ],
                            unique_by: [ :ts, :service, :metric ])
    begin
      PlainSeries.upsert_all!([ { ts: "2026-10-02 00:00:00", service: "web", metric: "cpu", kind: "gauge", value: 2.0 } ],
                              unique_by: [ :ts, :service, :metric ])
    rescue Sqlx::RecordNotUnique
      return
    end
    raise "expected Sqlx::RecordNotUnique from Sqlx::Base.upsert_all!"
  end

  # Empty rows: there is no statement to build — loud like the empty
  # inputs of the write family.
  def test_upsert_all_empty_rows_loud
    begin
      PlainSeries.upsert_all!([], unique_by: [ :ts ])
    rescue ArgumentError
      return
    end
    raise "expected ArgumentError from Sqlx::Base.upsert_all!"
  end

  # An empty unique_by has no conflict target: "any unique index"
  # is the silent policy this entry refuses to invent, and a plain
  # insert is create!'s job.
  def test_upsert_all_empty_unique_by_loud
    begin
      PlainSeries.upsert_all!([ { ts: "a", service: "web", metric: "cpu" } ], unique_by: [])
    rescue ArgumentError
      return
    end
    raise "expected ArgumentError from Sqlx::Base.upsert_all!"
  end

  # Differing row keys: one statement has one column list — loud
  # instead of a row quietly losing values to a missing key.
  def test_upsert_all_unequal_keys_loud
    begin
      PlainSeries.upsert_all!([
        { ts: "a", service: "web", metric: "cpu" },
        { ts: "b", service: "web" }
      ], unique_by: [ :ts ])
    rescue ArgumentError
      return
    end
    raise "expected ArgumentError from Sqlx::Base.upsert_all!"
  end

  # A conflict target outside the insert list would never fire — the
  # columns must be row keys, loud at the entry.
  def test_upsert_all_unique_by_outside_keys_loud
    begin
      PlainSeries.upsert_all!([ { ts: "a", service: "web" } ], unique_by: [ :ts, :metric ])
    rescue ArgumentError
      return
    end
    raise "expected ArgumentError from Sqlx::Base.upsert_all!"
  end

  # Nothing left to update: every row key is part of the conflict
  # target — a skip-duplicates statement is not this entry.
  def test_upsert_all_no_updatable_loud
    begin
      PlainSeries.upsert_all!([ { ts: "a" } ], unique_by: [ :ts ])
    rescue ArgumentError
      return
    end
    raise "expected ArgumentError from Sqlx::Base.upsert_all!"
  end

  # Undeclared model: the declaration stub raises before any SQL.
  def test_upsert_all_base_loud
    begin
      Sqlx::Base.upsert_all!([ { ts: "a" } ], unique_by: [ :ts ])
    rescue NotImplementedError
      return
    end
    raise "expected NotImplementedError from Sqlx::Base.upsert_all!"
  end

  # delete! end to end: the row is gone and the return is the
  # deleted-row count.
  def test_delete_removes_row_and_returns_count
    rec = SqlxWriteEntryModel.create!({ name: "doomed", email: "d@example.com" })
    deleted = SqlxWriteEntryModel.delete!(rec.id)
    assert_equal 1, deleted
    assert_equal false, SqlxWriteEntryModel.exists?(rec.id)
  end

  # An unknown id is silent: the count is 0 and no exception
  # rises — the caller's lookup already decided the 404 path.
  def test_delete_unknown_id_is_silent_zero
    deleted = SqlxWriteEntryModel.delete!(999)
    assert_equal 0, deleted
  end

  # Undeclared model: the declaration stub raises before any SQL.
  def test_delete_base_loud
    begin
      Sqlx::Base.delete!(1)
    rescue NotImplementedError
      return
    end
    raise "expected NotImplementedError from Sqlx::Base.delete!"
  end

  # An Array id is loud: it would bind as text and delete nothing
  # on one adapter while the driver errors on the other — the shapes
  # delete_all! owns instead.
  def test_delete_array_id_loud
    begin
      SqlxWriteEntryModel.delete!([1, 2, 3])
    rescue ArgumentError
      return
    end
    raise "expected ArgumentError from Sqlx::Base.delete!"
  end

  # A nil id is loud: `id = NULL` matches no row on every adapter, so
  # the silent-0 answer would hide a caller bug.
  def test_delete_nil_id_loud
    begin
      SqlxWriteEntryModel.delete!(nil)
    rescue ArgumentError
      return
    end
    raise "expected ArgumentError from Sqlx::Base.delete!"
  end

  # delete_all! end to end: every matching row goes and the return
  # is the deleted-row count.
  def test_delete_all_removes_matches_and_returns_count
    SqlxWriteEntryModel.create!({ name: "a", email: "a1@example.com" })
    SqlxWriteEntryModel.create!({ name: "a", email: "a2@example.com" })
    SqlxWriteEntryModel.create!({ name: "b", email: "b@example.com" })
    deleted = SqlxWriteEntryModel.delete_all!({ name: "a" })
    assert_equal 2, deleted
    assert_equal 1, SqlxWriteEntryModel.count
  end

  # The conditions rule rides where_clause: nil is IS NULL,
  # an Array is IN membership.
  def test_delete_all_array_condition
    SqlxWriteEntryModel.create!({ name: "x", email: "x1@example.com" })
    SqlxWriteEntryModel.create!({ name: "x", email: "x2@example.com" })
    SqlxWriteEntryModel.create!({ name: "y", email: "y@example.com" })
    deleted = SqlxWriteEntryModel.delete_all!({ name: ["x", "y"] })
    assert_equal 3, deleted
    assert_equal 0, SqlxWriteEntryModel.count
  end

  # nil conditions mean the whole table: every row goes and the
  # return is the deleted count — "every row" is the explicit nil,
  # never an empty hash.
  def test_delete_all_nil_conditions_whole_table
    SqlxWriteEntryModel.create!({ name: "a", email: "a@example.com" })
    SqlxWriteEntryModel.create!({ name: "b", email: "b@example.com" })
    deleted = SqlxWriteEntryModel.delete_all!(nil)
    assert_equal 2, deleted
    assert_equal 0, SqlxWriteEntryModel.count
  end

  # An empty conditions hash is the shape a broken condition builder
  # leaves behind — the whole table is the explicit nil, so an empty
  # hash raises instead of quietly erasing every row.
  def test_delete_all_empty_loud
    begin
      SqlxWriteEntryModel.delete_all!({})
    rescue ArgumentError
      return
    end
    raise "expected ArgumentError from Sqlx::Base.delete_all!"
  end

  # Undeclared model: the declaration stub raises before any SQL.
  def test_delete_all_base_loud
    begin
      Sqlx::Base.delete_all!({ name: "x" })
    rescue NotImplementedError
      return
    end
    raise "expected NotImplementedError from Sqlx::Base.delete_all!"
  end

  # The json round trip through a write entry and back: the caller
  # hands a logical Hash, the stored column is JSON text, and both the
  # re-read record and a fresh find carry the Hash again — no codec
  # call appears in app code.
  def test_json_column_roundtrips_through_create
    rec = SqlxJsonModel.create!({ name: "j1", detail: { "n" => 7 } })
    rows = Sqlx::Base.rows_by_sql("SELECT detail FROM json_samples WHERE name = ?", [ "j1" ])
    assert_equal '{"n":7}', rows[0]["detail"]
    assert_equal({ "n" => 7 }, rec.detail)
    found = SqlxJsonModel.find(rec.id)
    assert_equal({ "n" => 7 }, found.detail)
  end

  # A bare scalar number is the codec's scalar case: a JSON column may
  # store '42' as a number, so hydration recovers the serialized text
  # before decoding — the value comes back equal, not raised and not
  # reshaped.
  def test_json_column_scalar_number_roundtrips
    integer_rec = SqlxJsonModel.create!({ name: "j2", detail: 42 })
    float_rec = SqlxJsonModel.create!({ name: "j3", detail: 4.5 })
    assert_equal 42, integer_rec.detail
    assert_equal 4.5, float_rec.detail
  end

  # nil is the codec's nil both ways: a column the caller never
  # passed reads back as nil, never as a decoded null or a String.
  def test_json_column_nil_reads_nil
    rec = SqlxJsonModel.create!({ name: "j4" })
    assert_equal nil, rec.detail
  end

  # A value JSON cannot represent stops at the write entry — the
  # codec's contract, so a Time never reaches the column as text.
  def test_json_non_encodable_value_loud
    begin
      SqlxJsonModel.create!({ name: "j5", detail: Time.now })
    rescue ArgumentError
      return
    end
    raise "expected ArgumentError from the json write entry"
  end

  # A json declaration outside only_columns fails at hydration — the
  # same loud rule as the other type exceptions, never raw text
  # returned under a declared name.
  def test_json_declaration_outside_only_columns_loud
    rec = SqlxJsonModel.create!({ name: "j6", detail: { "seed" => true } })
    begin
      SqlxBadJsonModel.find(rec.id)
    rescue ArgumentError
      return
    end
    raise "expected ArgumentError from the unknown declared json column"
  end

  # No declaration means raw storage: the column stores and reads
  # exactly what it holds — the default json list is no codec at all.
  def test_undeclared_json_column_stays_raw_text
    rec = SqlxRawJsonModel.create!({ name: "raw1", detail: '{"raw":true}' })
    found = SqlxRawJsonModel.find(rec.id)
    assert_equal '{"raw":true}', found.detail
  end

  # update! encodes the same way create! does — the attr's logical
  # value becomes stored text and the re-read record carries it back.
  def test_update_encodes_json_column
    rec = SqlxJsonModel.create!({ name: "j7", detail: { "v" => 1 } })
    updated = SqlxJsonModel.update!(rec.id, { detail: { "v" => 2 } })
    rows = Sqlx::Base.rows_by_sql("SELECT detail FROM json_samples WHERE id = ?", [ rec.id ])
    assert_equal '{"v":2}', rows[0]["detail"]
    assert_equal({ "v" => 2 }, updated.detail)
  end

  # update_all! encodes the SET side — the same declared column, the
  # same codec, through the batch entry.
  def test_update_all_encodes_json_column
    SqlxJsonModel.create!({ name: "b1", detail: { "v" => 1 } })
    SqlxJsonModel.create!({ name: "b2", detail: { "v" => 1 } })
    changed = SqlxJsonModel.update_all!({ name: [ "b1", "b2" ] }, { detail: { "batch" => true } })
    assert_equal 2, changed
    rows = Sqlx::Base.rows_by_sql("SELECT detail FROM json_samples ORDER BY name")
    assert_equal '{"batch":true}', rows[0]["detail"]
    assert_equal '{"batch":true}', rows[1]["detail"]
  end

  # upsert_all! encodes every row's declared column — the bulk entry
  # takes the same logical values as create!.
  def test_upsert_all_encodes_json_column
    changed = SqlxJsonModel.upsert_all!([
      { name: "u1", detail: { "a" => 1 } },
      { name: "u2", detail: { "a" => 2 } }
    ], unique_by: [ :name ])
    assert_equal 2, changed
    rows = Sqlx::Base.rows_by_sql("SELECT detail FROM json_samples ORDER BY name")
    assert_equal '{"a":1}', rows[0]["detail"]
    assert_equal '{"a":2}', rows[1]["detail"]
  end
end

# The model under test: reads its one column by name and counts the
# calls so the test can pin the dispatch.
# The counter is an int accumulator — spinel gives a bare [] an int
# slot, so recording strings through push would be refused at compile.
class SqlxCaptureModel < Sqlx::Base
  def self.calls
    @calls ||= 0
  end

  def self.reset
    @calls = 0
  end

  def self.from_row(row)
    @calls += 1
    row["name"]
  end

  # The declaration pair behind the inherited find_by: the model
  # owns table and column list, the core method owns the assembly —
  # no per-model find_by override exists here on purpose.
  def self.table_name = "samples"
  def self.only_columns = [:name]

  # The spec-only all, in the recipe shape from the spec comment:
  # the walk stays in the model so the element type converges.
  def self.all = find_by_sql("SELECT name FROM samples")
end

# The reserved-word model behind the quoting check: its single
# column `order` cannot appear in SQL unquoted, so a find_by that
# returns a row proves the core assembly quotes identifiers.
class SqlxReservedModel < Sqlx::Base
  def self.table_name = "ordered_items"
  def self.only_columns = [:order]

  def self.from_row(row)
    row["order"]
  end
end

# The wrapper-free multi-row fixture: from_row yields a record (the
# object element the typed-array refusal class needed), and a reader
# in another class calls the inherited walk cross-class — the sidecar
# .rbs declares its Array[<Model>] return, which the specialized walk
# must satisfy at compile time.
class SqlxRowModel < Sqlx::Base
  attr_reader :name

  def initialize(name)
    @name = name
  end

  def self.table_name = "samples"
  def self.only_columns = [:name]

  def self.from_row(row)
    SqlxRowModel.new(row["name"])
  end
end

# The hash-backed accessor path: no Struct and no hand-written
# initialize — the literal accessor loop generates the readers
# (spinel unrolls the class-body literal `%w[].each` +
# define_method form), core's generic initialize stores the row,
# and every read routes through the core-owned read_attribute seam, so
# the storage behind the readers can change without touching this
# model.
class SqlxLoopModel < Sqlx::Base
  %w[id name].each do |n|
    define_method(n) { read_attribute(n) }
  end

  def self.table_name = "samples"
  def self.only_columns = [:id, :name]

  def self.from_row(row)
    new(id: row["id"], name: row["name"])
  end
end

class SqlxCrossReader
  def self.read_samples
    SqlxRowModel.find_by_sql("SELECT name FROM samples ORDER BY id")
  end

  def self.read_by_name(name)
    SqlxRowModel.fetch_many({ name: name })
  end

  def self.read_loop_rows
    SqlxLoopModel.fetch_many({ id: [1, 3] }, order: :asc)
  end
end

# The batch-walk fixture: only_columns carries the id cursor, and
# from_row counts calls so a test can prove the walk hydrates one batch
# at a time instead of the whole table up front.
class SqlxEachModel < Sqlx::Base
  def self.calls
    @calls ||= 0
  end

  def self.reset
    @calls = 0
  end

  def self.from_row(row)
    @calls += 1
    row["name"]
  end

  def self.table_name = "samples"
  def self.only_columns = [:id, :name]
end

# The write-entry model: the hash-backed path over the fixture with
# both declared timestamps and a UNIQUE email, so create!/update!
# stamping, the UNIQUE check, and the re-read all ride one
# declaration pair. No from_row: the built-in stamps convert by
# default.
class SqlxWriteEntryModel < Sqlx::Base
  %w[id name email created_at updated_at].each do |n|
    define_method(n) { read_attribute(n) }
  end

  def self.table_name = "write_entries"
  def self.only_columns = [:id, :name, :email, :created_at, :updated_at]
end

# The default-hydration fixture: no from_row on the model — the
# inherited walk copies the projected columns and converts the
# declared datetime list (the option replaces the default stamp
# pair, so it spells both stamps plus the extra seen_at) and the
# boolean flag. A model carries a from_row method only when its row
# needs more than the declaration.
class SqlxDeclaredModel < Sqlx::Base
  %w[id name created_at seen_at flag].each do |n|
    define_method(n) { read_attribute(n) }
  end

  def self.table_name = "declared_samples"
  def self.only_columns = [:id, :name, :created_at, :seen_at, :flag]
  def self.datetime_columns = %w[created_at updated_at seen_at]
  def self.boolean_columns = %w[flag]
end

# The stamp-less fixture: the built-in stamps are always legal
# datetime columns, and this table has neither — the default
# hydration must pass them by (not raise) instead of demanding
# columns the model never declared.
class SqlxStamplessModel < Sqlx::Base
  %w[id name].each do |n|
    define_method(n) { read_attribute(n) }
  end

  def self.table_name = "samples"
  def self.only_columns = [:id, :name]
end

# The declaration-typo fixture: its datetime exception names a
# column outside only_columns, so the default hydration must fail
# loud instead of staying raw silently (only the built-in stamps are
# exempt from the check).
class SqlxBadDeclaredModel < Sqlx::Base
  def self.table_name = "declared_samples"
  def self.only_columns = [:id, :name]
  def self.datetime_columns = %w[bogus_at]
end

# The upsert fixture model: a table with no primary key — identity is
# the series key, which is what upsert_all!'s required conflict
# target is for.
class PlainSeries < Sqlx::Base
  def self.table_name = "plain_series"
  def self.only_columns = [ :ts, :service, :metric, :kind, :value ]
end

# The json declaration fixture: the write entries encode the declared
# column and the default from_row decodes it, so the caller only ever
# hands over and receives logical values.
class SqlxJsonModel < Sqlx::Base
  %w[id name detail].each do |n|
    define_method(n) { read_attribute(n) }
  end

  def self.table_name = "json_samples"
  def self.only_columns = [:id, :name, :detail]
  def self.json_columns = %w[detail]
end

# The json declaration-typo fixture: its exception names a column
# outside only_columns, so the default hydration must fail loud
# instead of returning raw text under the declared name.
class SqlxBadJsonModel < Sqlx::Base
  def self.table_name = "json_samples"
  def self.only_columns = [:id, :name]
  def self.json_columns = %w[bogus]
end

# The undeclared json fixture: the model keeps the column raw — the
# default json list is empty and neither entry touches the value.
class SqlxRawJsonModel < Sqlx::Base
  %w[id name detail].each do |n|
    define_method(n) { read_attribute(n) }
  end

  def self.table_name = "json_samples"
  def self.only_columns = [:id, :name, :detail]
end

FixtureRunner.run(SqlxTest, [
  "test_base_from_row_loud",
  "test_find_by_sql_maps_rows",
  "test_cross_class_typed_array",
  "test_empty_result",
  "test_exists_does_not_hydrate",
  "test_rows_by_sql_returns_hash_rows",
  "test_rows_by_sql_aggregate",
  "test_rows_by_sql_empty_is_array",
  "test_rows_by_sql_does_not_hydrate",
  "test_find_by_base_loud",
  "test_find_by_bang_base_loud",
  "test_declaration_stubs_base_loud",
  "test_projection_qualifies_and_quotes",
  "test_projection_quotes_reserved_column",
  "test_projection_base_loud",
  "test_where_clause_nil_is_null",
  "test_where_clause_is_not_null",
  "test_where_clause_escapes_values",
  "test_where_clause_boolean_renders_the_adapter_spelling",
  "test_where_clause_joins_with_and",
  "test_where_clause_empty_loud",
  "test_where_clause_array_membership",
  "test_where_clause_array_escapes_elements",
  "test_where_clause_time_renders_the_stored_form",
  "test_where_clause_time_matches_a_stored_row",
  "test_where_clause_array_joins_with_and",
  "test_where_clause_array_empty_loud",
  "test_where_clause_array_nil_element_loud",
  "test_where_clause_comparison_predicates",
  "test_where_clause_comparison_matches_stored_rows",
  "test_where_clause_comparison_unknown_operator_loud",
  "test_where_clause_comparison_empty_hash_loud",
  "test_where_clause_comparison_nil_bound_loud",
  "test_where_clause_comparison_nested_bound_loud",
  "test_where_clause_is_not_bound_loud",
  "test_where_clause_array_operator_hash_loud",
  "test_find_by_empty_loud",
  "test_find_by_via_where_clause",
  "test_find_by_is_not_null_condition",
  "test_find_by_time_condition_binds_to_the_stored_form",
  "test_find_by_binds_a_quoted_string",
  "test_find_by_quotes_reserved_column",
  "test_find_by_bang_miss_raises",
  "test_count_returns_row_count",
  "test_count_empty_table_is_zero",
  "test_count_with_conditions",
  "test_count_is_not_null_condition",
  "test_read_binds_its_values",
  "test_step_error_is_not_an_empty_result",
  "test_read_without_values_is_loud",
  "test_find_by_sql_without_values_is_loud",
  "test_row_by_sql_takes_values",
  "test_row_by_sql_returns_the_first_row",
  "test_count_base_loud",
  "test_find_returns_record",
  "test_find_miss_raises",
  "test_find_base_loud",
  "test_exists_with_conditions",
  "test_exists_positional_id",
  "test_exists_any_row",
  "test_exists_nil_is_false",
  "test_exists_base_loud",
  "test_all_base_loud",
  "test_all_via_recipe",
  "test_find_by_order_desc_returns_last_match",
  "test_find_by_order_asc_returns_first_match",
  "test_find_by_empty_with_order_returns_table_edge",
  "test_find_by_invalid_order_loud",
  "test_find_by_array_condition",
  "test_find_by_array_condition_with_order",
  "test_fetch_many_single_match_is_array",
  "test_fetch_many_empty_result",
  "test_fetch_many_array_condition",
  "test_fetch_many_is_not_null_condition",
  "test_fetch_many_order_desc",
  "test_fetch_many_order_asc",
  "test_fetch_many_invalid_order_loud",
  "test_fetch_many_empty_loud",
  "test_fetch_many_nil_conditions_whole_table",
  "test_fetch_many_nil_conditions_order",
  "test_fetch_many_base_loud",
  "test_fetch_many_cross_class_typed_array",
  "test_fetch_many_limit_returns_the_first_n",
  "test_fetch_many_limit_without_order_bounds_the_read",
  "test_fetch_many_limit_offset_pages_without_repeats",
  "test_fetch_many_limit_with_conditions",
  "test_fetch_many_limit_beyond_rows_returns_all",
  "test_fetch_many_limit_zero_loud",
  "test_fetch_many_negative_limit_loud",
  "test_fetch_many_offset_without_limit_loud",
  "test_fetch_many_offset_without_order_loud",
  "test_fetch_many_negative_offset_loud",
  "test_find_each_nil_conditions_walks_the_whole_table",
  "test_find_each_default_batch_size_walks_the_whole_table",
  "test_find_each_yields_model_records",
  "test_find_each_batch_size_one_hits_every_boundary",
  "test_find_each_exact_batch_size_does_not_repeat",
  "test_find_each_conditions_filter_rows",
  "test_find_each_id_condition_combines_with_the_cursor",
  "test_find_each_cursor_is_keyset_not_offset",
  "test_find_each_empty_result_yields_nothing",
  "test_find_each_empty_conditions_loud",
  "test_find_each_non_positive_batch_size_loud",
  "test_find_each_requires_a_block",
  "test_find_each_requires_id_projection",
  "test_find_each_base_loud",
  "test_find_each_break_stops_the_walk",
  "test_find_each_hydrates_one_batch_at_a_time",
  "test_find_in_batches_yields_batch_arrays",
  "test_find_in_batches_default_batch_size_is_one_batch",
  "test_find_in_batches_exact_batch_size_does_not_repeat",
  "test_find_in_batches_conditions_filter_rows",
  "test_find_in_batches_yields_model_records",
  "test_find_in_batches_cursor_is_keyset_not_offset",
  "test_find_in_batches_bulk_update_per_batch",
  "test_find_in_batches_empty_result_yields_nothing",
  "test_find_in_batches_empty_conditions_loud",
  "test_find_in_batches_non_positive_batch_size_loud",
  "test_find_in_batches_requires_a_block",
  "test_find_in_batches_requires_id_projection",
  "test_find_in_batches_base_loud",
  "test_find_in_batches_break_stops_the_walk",
  "test_find_in_batches_hydrates_one_batch_at_a_time",
  "test_loop_find_by",
  "test_loop_fetch_many",
  "test_loop_declarations",
  "test_loop_count",
  "test_loop_cross_class_typed_array",
  "test_loop_unknown_attribute_loud",
  "test_loop_missing_attribute_is_nil",
  "test_default_hydration_converts_declared_columns",
  "test_default_stamps_skip_when_table_lacks_them",
  "test_default_hydration_unknown_declared_column_loud",
  "test_hydration_is_column_order_independent",
  "test_null_column_reads_as_nil",
  "test_create_returns_persisted_record",
  "test_create_with_explicit_id_returns_that_row",
  "test_create_caller_timestamp_wins",
  "test_create_empty_attrs_loud",
  "test_create_unique_violation_raises_not_unique",
  "test_create_base_loud",
  "test_update_returns_persisted_record",
  "test_update_refreshes_updated_at",
  "test_update_caller_timestamp_wins",
  "test_update_unknown_id_raises",
  "test_update_empty_attrs_loud",
  "test_update_base_loud",
  "test_update_all_returns_affected_count",
  "test_update_all_range_conditions",
  "test_update_all_binds_caller_time",
  "test_update_all_does_not_stamp",
  "test_update_all_nil_conditions_whole_table",
  "test_update_all_empty_conditions_loud",
  "test_update_all_empty_attrs_loud",
  "test_update_all_unknown_column_loud",
  "test_update_all_base_loud",
  "test_upsert_all_writes_and_rewrites",
  "test_upsert_all_other_unique_index_raises",
  "test_upsert_all_empty_rows_loud",
  "test_upsert_all_empty_unique_by_loud",
  "test_upsert_all_unequal_keys_loud",
  "test_upsert_all_unique_by_outside_keys_loud",
  "test_upsert_all_no_updatable_loud",
  "test_upsert_all_base_loud",
  "test_delete_removes_row_and_returns_count",
  "test_delete_unknown_id_is_silent_zero",
  "test_delete_base_loud",
  "test_delete_array_id_loud",
  "test_delete_nil_id_loud",
  "test_delete_all_removes_matches_and_returns_count",
  "test_delete_all_array_condition",
  "test_delete_all_nil_conditions_whole_table",
  "test_delete_all_empty_loud",
  "test_delete_all_base_loud",
  "test_json_column_roundtrips_through_create",
  "test_json_column_scalar_number_roundtrips",
  "test_json_column_nil_reads_nil",
  "test_json_non_encodable_value_loud",
  "test_json_declaration_outside_only_columns_loud",
  "test_undeclared_json_column_stays_raw_text",
  "test_update_encodes_json_column",
  "test_update_all_encodes_json_column",
  "test_upsert_all_encodes_json_column"
])
