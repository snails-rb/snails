module Sqlx
  # The query surface: every class-side entry that runs or assembles SQL.
  # Extended onto Base, so each method is a model class method.
  #
  # Binding contract for every entry that takes `sql` and `values`: values
  # enter the statement only through the values list, one per `?`, and the
  # list count must match the placeholder count. A mismatch raises
  # `ArgumentError` — a missing value would bind NULL and a surplus one
  # would be dropped, both silently. A statement with no `?` is called
  # without the list (`rows_by_sql(sql)`), not with an empty array. Within
  # the list, nil binds SQL NULL, a Time binds in the runtime's stored form
  # (UTC), and every other value binds by its Ruby type. A value spliced
  # into the SQL text is outside this contract — the caller's own escaping.
  module Query
    # Runs a caller-written SELECT and builds one record per row through the
    # receiver's `from_row`. The caller owns the SQL (column list, join,
    # condition); the row is read by column name, so the SELECT's column
    # order never binds record building.
    #
    # The receiver fixes the record class, so a caller may declare
    # `Array[<Model>]` and the call returns that element type.
    #
    # @param sql [String] the caller's SELECT, with a `?` for each value
    # @param values [Array, nil] the bound values, one per `?`; nil when the
    #   statement takes none (the binding contract above)
    # @return [Array] one record per row, built by the receiver's `from_row`
    # @raise [ArgumentError] the values and the placeholders do not agree
    # @example typed association reader — declaration and call agree
    #   # rbs: def subscriptions: () -> Array[Subscription]
    #   def subscriptions
    #     Subscription.find_by_sql("SELECT " + Subscription.projection +
    #       " FROM subscriptions WHERE user_id = ?", [ @id ])
    #   end
    def find_by_sql(sql, values = nil)
      rows_by_sql(sql, values).map { |row| from_row(row) }
    end

    # Runs a caller-written SELECT and returns its first row as a column-name
    # Hash, or nil when the statement returns no row. It is the raw form of
    # `find_by_sql(...).first`: the same query, without record building. The
    # statement is read in full, so bound a large result with `LIMIT`.
    #
    # @param sql [String] the caller's SELECT, with a `?` for each value
    # @param values [Array, nil] the bound values, one per `?`; nil when the
    #   statement takes none (the binding contract above)
    # @return [Hash{String => Object}, nil] the first row, keyed by column
    #   name; nil when the statement returned no row
    # @raise [ArgumentError] the values and the placeholders do not agree
    # @example
    #   Sqlx::Base.row_by_sql("SELECT id, name FROM widgets LIMIT 1")
    #   # => { "id" => 7, "name" => "alpha" }
    #   Sqlx::Base.row_by_sql("SELECT id, name FROM widgets WHERE id = ?", [ 7 ])
    def row_by_sql(sql, values = nil)
      rows = rows_by_sql(sql, values)
      if rows.empty?
        nil
      else
        rows[0]
      end
    end

    # Runs a caller-written SELECT and returns each row as a Hash keyed by
    # column name, without building records. Use it when no model describes
    # the row: a view, an aggregate, or a computed column. `from_row` receives
    # rows in exactly this shape, so a raw row and a built record read the same
    # way.
    #
    # @param sql [String] the caller's SELECT, with a `?` for each value
    # @param values [Array, nil] the bound values, one per `?`; nil when the
    #   statement takes none (the binding contract above)
    # @return [Array] one Hash per row, keyed by column name — an empty array
    #   when the statement returns no row (never nil); values are the
    #   adapter's native types (Integer, Float, String, or nil for NULL)
    # @raise [ArgumentError] the values and the placeholders do not agree
    # @example view read — no model fits the row shape
    #   Sqlx::Base.rows_by_sql("SELECT service, host FROM latest_samples")
    # @example a read with a value — bound, not spliced into the text
    #   Sqlx::Base.rows_by_sql("SELECT id FROM widgets WHERE name = ?", [ "alpha" ])
    def rows_by_sql(sql, values = nil)
      bound = values_for_placeholders(sql, values)
      Sqlx::Database.exec_read(sql, bound)
    end

    # Runs the block with a dedicated read-only connection. The connection is
    # for SQL the caller did not write ahead of time — a view, a dashboard, or
    # a statement built by an agent — so it refuses writes and `ATTACH` at the
    # database layer and applies a row cap and a wall-clock timeout to every
    # query.
    #
    # The block receives a `Sqlx::ReadConnection`; the scope opens the
    # connection before the block and closes it after, including when the block
    # raises. The block's value is returned.
    #
    # The SQLite adapter implements this scope; the PostgreSQL adapter follows
    # in a companion change.
    #
    # @param max_rows [Integer] the row cap each query may return; must be positive
    # @param timeout_ms [Integer] the wall-clock limit for each query; must be positive
    # @yieldparam reader [Sqlx::ReadConnection] the scope's read-only connection
    # @return [Object] the block's value
    # @raise [ArgumentError] either limit is not a positive Integer
    # @raise [RuntimeError] the database is not configured, or it is in-memory
    # @example
    #   Sqlx::Base.with_read_only(max_rows: 200, timeout_ms: 10_000) do |reader|
    #     result = reader.query("SELECT service, COUNT(*) AS n FROM logs GROUP BY service")
    #     result.columns    # => ["service", "n"]
    #     result.rows       # => [["telemetry", 10]]
    #     result.truncated? # => false
    #   end
    def with_read_only(max_rows:, timeout_ms:)
      unless max_rows.is_a?(Integer) && max_rows > 0
        raise ArgumentError, "max_rows must be a positive Integer"
      end
      unless timeout_ms.is_a?(Integer) && timeout_ms > 0
        raise ArgumentError, "timeout_ms must be a positive Integer"
      end
      reader = Sqlx::ReadConnection.new(Sqlx::Database.open_read_only, max_rows, timeout_ms)
      begin
        yield reader
      ensure
        reader.close
      end
    end

    # Runs a caller-written INSERT, UPDATE, or DELETE with its values bound,
    # and returns the rows the statement produced. A statement without
    # `RETURNING` returns an empty array; a `RETURNING` statement returns one
    # row per changed row, which is how a caller learns which row it wrote.
    #
    # A caller that needs the changed-row count reads
    # `Sqlx::Database.exec_write(sql, values)["count"]`; the model layer's
    # `update_all!` and `delete_all!` answer the same question from their own
    # entries.
    #
    # @param sql [String] the caller's INSERT/UPDATE/DELETE, with a `?` for
    #   each value
    # @param values [Array, nil] the bound values, one per `?`; nil when the
    #   statement takes none (the binding contract above)
    # @return [Array] one name-keyed Hash per row the statement returned — an
    #   empty array when it returned none
    # @raise [ArgumentError] the values and the placeholders do not agree
    # @example
    #   Model.write("INSERT INTO t (a) VALUES (?)", [ "x" ])
    #   # => []
    #   Model.write("UPDATE t SET a = ? WHERE id = ? RETURNING id", [ "x", 7 ])
    #   # => [ { "id" => 7 } ]
    #   Model.write("DELETE FROM t")
    #   # => []
    def write(sql, values = nil)
      bound = values_for_placeholders(sql, values)
      Sqlx::Database.exec_write(sql, bound)["rows"]
    end

    # Returns the WHERE clause body for a conditions hash: one predicate per
    # column, joined with AND, with each value rendered as a literal. It is
    # the literal form for a caller that assembles its own SQL; the query
    # entries above take the same conditions contract and bind the values (the
    # binding contract above). Both forms run the same validation and produce
    # the same predicates.
    #
    # Values are data, often from request params, and render through
    # `Sqlx.quote`, never raw. This form does not apply the integer column
    # cast: it renders the value as written, for a caller that owns the SQL.
    #
    # @param conditions [Hash{Symbol => Object}] column => value. nil renders
    #   `IS NULL`; an Array renders `IN (...)`; an operator Hash renders the
    #   comparison (`:lt`, `:lte`, `:gt`, `:gte`) or the null test
    #   (`is_not: nil` → `IS NOT NULL`); anything else renders equality. Keys
    #   are code, not input, and are not validated: an unknown column
    #   surfaces as a SQL error from the driver.
    # @return [String] the clause body — no `WHERE` keyword, ready to splice
    #   into the caller's SELECT
    # @raise [ArgumentError] on an empty hash (there is no clause to build);
    #   on an empty Array value or one carrying nil or a Hash (`IN ()` is not
    #   SQL, `IN (NULL, ...)` never matches, membership takes values); on an
    #   empty operator hash; on an operator outside the whitelist; on a nil or
    #   structured comparison bound (`< NULL` never matches, and a nested Hash
    #   would stringify into the comparison); or on `is_not` with a bound
    #   other than nil (`IS NOT <value>` is not SQL — the operator is the null
    #   test)
    #
    # @example
    #   where_clause({ email: "a@example.com", deleted_at: nil })
    #   # => "email = 'a@example.com' AND deleted_at IS NULL"
    #   where_clause({ user_id: 7, status: [0, 1] })
    #   # => "user_id = 7 AND status IN (0, 1)"
    #   where_clause({ deleted_at: { is_not: nil } })
    #   # => "deleted_at IS NOT NULL"
    #   where_clause({ started_at: { lt: Time.utc(2026, 10, 6, 8, 0, 0) } })
    #   # => "started_at < '2026-10-06 08:00:00.000000'"
    def where_clause(conditions)
      raise ArgumentError, "where_clause: conditions must not be empty" if conditions.empty?
      parts = []
      conditions.each do |key, value|
        parts << condition_predicate(key.to_s, value, false)[0]
      end
      parts.join(" AND ")
    end

    # Returns the model's SELECT column list: every declared column,
    # table-qualified and quoted, joined with commas. `find_by` and a
    # caller-written SELECT build the same spelling, and a join reader calls
    # another model's `projection` to get that model's table and columns — the
    # receiver is the source of both.
    #
    # @return [String] the qualified column list, ready to follow `SELECT`
    # @raise [NotImplementedError] the model has not declared `table_name` /
    #   `only_columns` (the declaration stubs raise)
    # @example
    #   Widget.projection
    #   # => "\"widgets\".\"id\", \"widgets\".\"email\""
    def projection
      quoted_table = '"' + table_name + '"'
      parts = []
      only_columns.each { |column| parts << quoted_table + '."' + column.to_s + '"' }
      parts.join(", ")
    end

    # Returns the single row matching a conditions hash, or nil when none
    # matches. The SELECT is assembled from the model's `table_name` and
    # `only_columns`; a model whose lookup needs more (a default scope, a join)
    # overrides this method.
    #
    # `order:` decides which match arrives: `:desc` is the match with the
    # highest `id`, `:asc` the lowest. An empty hash is allowed only with
    # `order:` — `find_by({}, order: :desc)` is the table's last row and
    # `:asc` its first. Without `order:`, the matching row is
    # implementation-defined.
    #
    # Conditions follow the `where_clause` contract, with values bound. Table
    # and column identifiers are quoted; condition keys are not — keys are
    # code, not input.
    #
    # @param conditions [Hash{Symbol => Object}] the `where_clause` conditions
    #   contract, with values bound. Keys are not validated: an unknown column
    #   surfaces as a SQL error from the driver, never as nil. An empty hash is
    #   allowed only with `order:`.
    # @param order [Symbol, nil] `:desc` or `:asc` — the `id` direction that
    #   picks the row; nil leaves the row implementation-defined
    # @return [Object, nil] the matching record, or nil on no match — at most
    #   one row; with `order:` the highest/lowest `id` among the matches
    # @raise [NotImplementedError] the model has not declared
    #   `table_name` / `only_columns` (the declaration stubs raise)
    # @raise [ArgumentError] an empty conditions hash with no `order:` — there
    #   is no clause to build and no row question to ask; an `order:` other
    #   than `:asc`/`:desc` (a typo must raise, not silently pick a row); or a
    #   conditions value the `where_clause` contract rejects
    # @raise [Sqlx::CastError] a String value on a column declared in
    #   `integer_columns` is not a decimal integer
    # @example call
    #   Model.find_by({ email: "a@example.com", deleted_at: nil })
    #   InvoiceItem.find_by({ invoice_id: 42 }, order: :desc)
    #   Subscription.find_by({ user_id: 7, status: [0, 1] }, order: :desc)
    #   Plan.find_by({}, order: :desc)  # the table's last row
    # @example declaration — the model owns table and columns, the
    #   inherited method owns the assembly
    #   class Widget < Sqlx::Base
    #     def self.table_name = "widgets"
    #     def self.only_columns = [:id, :email, :created_at]
    #   end
    def find_by(conditions, order: nil)
      unless order.nil? || order == :asc || order == :desc
        raise ArgumentError, "find_by: order must be :asc or :desc"
      end
      if conditions.empty? && order.nil?
        raise ArgumentError, "find_by: conditions must not be empty"
      end
      quoted_table = '"' + table_name + '"'
      sql = "SELECT " + projection + " FROM " + quoted_table
      values = []
      unless conditions.empty?
        pair = where_clause_values(conditions)
        sql += " WHERE " + pair[0]
        values = pair[1]
      end
      sql += ' ORDER BY "id" ' + (order == :asc ? "ASC" : "DESC") unless order.nil?
      one_by_sql(sql + " LIMIT 1", values)
    end

    # Returns the single row matching a conditions hash, or raises
    # `Sqlx::RecordNotFound` when none matches. The bang form is for a caller
    # that treats an absent record as a 404; the message names the table.
    #
    # @param conditions [Hash{Symbol => Object}] the `find_by` conditions
    #   contract, unchanged
    # @return [Object] the matching record — never nil
    # @raise [Sqlx::RecordNotFound] no row matches the conditions
    # @raise [NotImplementedError] the model has not declared
    #   `table_name` / `only_columns`
    # @raise [ArgumentError] the `find_by` conditions contract rejects the
    #   conditions
    # @example
    #   Model.find_by!({ email: "a@example.com" })
    def find_by!(conditions)
      result = find_by(conditions)
      raise Sqlx::RecordNotFound, "Couldn't find " + table_name if result.nil?
      result
    end

    # Returns every row matching a conditions hash, or the whole table when
    # `conditions` is nil. The SELECT is assembled from the model's
    # `table_name` and `only_columns`, like `find_by`.
    #
    # `order:` sorts the returned rows by `id`: `:desc` highest first, `:asc`
    # lowest. Without it, the row order is implementation-defined. `limit:`
    # returns at most N rows. `offset:` skips N rows for a numbered page and
    # requires both `limit:` and `order:` — an offset without a sort can repeat
    # or skip rows while writes land, and an offset without a limit reads every
    # remaining row. A full-table read belongs to `find_each`.
    #
    # nil conditions mean the whole table. An empty hash raises: it is what a
    # broken condition builder leaves behind, so it must not widen into every
    # row (the same rule `update_all!` and `delete_all!` keep).
    #
    # @param conditions [Hash{Symbol => Object}, nil] the `where_clause`
    #   conditions contract, with values bound; nil means the whole table (no
    #   WHERE clause at all)
    # @param order [Symbol, nil] `:desc` or `:asc` — the `id` sort direction of
    #   the returned rows; nil leaves the order implementation-defined
    # @param limit [Integer, nil] the maximum number of rows to return; nil
    #   means no limit. Must be positive.
    # @param offset [Integer, nil] how many matching rows to skip before
    #   collecting the window; nil means zero. Requires both `limit:` and
    #   `order:`.
    # @return [Array] one record per matching row in the window, built by the
    #   receiver's `from_row` — an empty array on no match (never nil)
    # @raise [ArgumentError] an empty conditions hash — the whole table is
    #   spelled nil, so an empty hash means the condition builder broke; an
    #   `order:` other than `:asc`/`:desc` (a typo must raise, not silently
    #   return unordered rows); a `limit:` that is not a positive Integer; an
    #   `offset:` that is not a non-negative Integer, or that arrives without
    #   `limit:` or `order:`; or a conditions value the `where_clause` contract
    #   rejects
    # @raise [Sqlx::CastError] a String value on a column declared in
    #   `integer_columns` is not a decimal integer
    # @raise [NotImplementedError] the model has not declared
    #   `table_name` / `only_columns` (the declaration stubs raise)
    # @example typed association reader — declaration and call agree
    #   # rbs: def invoices: () -> Array[Invoice]
    #   def invoices = Invoice.fetch_many({ user_id: @id }, order: :desc)
    # @example the whole table, sorted — nil is the explicit "every row"
    #   User.fetch_many(nil, order: :desc)
    # @example a page — both the window and the total stay explicit
    #   total = Invoice.count({ user_id: id })
    #   page = Invoice.fetch_many({ user_id: id }, order: :desc, limit: 20, offset: 40)
    def fetch_many(conditions, order: nil, limit: nil, offset: nil)
      unless order.nil? || order == :asc || order == :desc
        raise ArgumentError, "fetch_many: order must be :asc or :desc"
      end
      unless limit.nil? || (limit.is_a?(Integer) && limit > 0)
        raise ArgumentError, "fetch_many: limit must be a positive Integer"
      end
      unless offset.nil? || (offset.is_a?(Integer) && offset >= 0)
        raise ArgumentError, "fetch_many: offset must be a non-negative Integer"
      end
      if !offset.nil? && limit.nil?
        raise ArgumentError, "fetch_many: offset requires limit — an offset without a limit reads the whole tail"
      end
      if !offset.nil? && order.nil?
        raise ArgumentError, "fetch_many: offset requires order — a page without a sort can repeat or skip rows"
      end
      if !conditions.nil? && conditions.empty?
        raise ArgumentError, "fetch_many: conditions must not be an empty hash — pass nil to read the whole table"
      end
      quoted_table = '"' + table_name + '"'
      sql = "SELECT " + projection + " FROM " + quoted_table
      values = []
      unless conditions.nil?
        pair = where_clause_values(conditions)
        sql += " WHERE " + pair[0]
        values = pair[1]
      end
      sql += ' ORDER BY "id" ' + (order == :asc ? "ASC" : "DESC") unless order.nil?
      unless limit.nil?
        sql += " LIMIT ?"
        values << limit
        unless offset.nil?
          sql += " OFFSET ?"
          values << offset
        end
      end
      find_by_sql(sql, values)
    end

    # Yields every row matching the conditions, one record at a time, in `id`
    # order. The read is keyset paginated: each query asks for the rows after
    # the last id seen, so a static table is visited exactly once and no
    # OFFSET arithmetic is involved. `find_in_batches` is the bulk form that
    # yields a batch instead.
    #
    # `batch_size` is the page size, not a total cap — for at most N rows use
    # `fetch_many(..., limit: N)`. The read is not a snapshot: a row inserted
    # with a higher id during the walk may be seen, and changing an id
    # mid-walk is outside the contract. A `break` in the block stops the walk.
    #
    # The `id` column is the cursor and must be in `only_columns`. A table
    # without `id`, a join, or a descending full read uses raw `find_by_sql`.
    #
    # @param conditions [Hash{Symbol => Object}, nil] the `where_clause`
    #   conditions contract, with values bound; nil means the whole table and
    #   an empty hash raises (a broken condition builder must not widen into a
    #   full read)
    # @param batch_size [Integer] how many rows one query reads; must be
    #   positive
    # @return [void]
    # @raise [ArgumentError] the block is missing; the conditions hash is
    #   empty; `batch_size` is not a positive Integer; or `only_columns` omits
    #   `id` (the cursor column)
    # @raise [Sqlx::CastError] a String condition value on a column declared in
    #   `integer_columns` is not a decimal integer
    # @raise [NotImplementedError] the model has not declared
    #   `table_name` / `only_columns` (the declaration stubs raise)
    # @example
    #   InvoiceItem.find_each(nil, batch_size: 500) { |item| item.reindex }
    # @example resume after a recorded id — the conditions carry the start
    #   Job.find_each({ id: { gt: last_seen_id } }, batch_size: 500) { |job| ... }
    def find_each(conditions = nil, batch_size: 1000)
      unless block_given?
        raise ArgumentError, "find_each: block required"
      end
      unless batch_size.is_a?(Integer) && batch_size > 0
        raise ArgumentError, "find_each: batch_size must be a positive Integer"
      end
      if !conditions.nil? && conditions.empty?
        raise ArgumentError, "find_each: conditions must not be an empty hash — pass nil to read the whole table"
      end
      unless only_columns.map { |column| column.to_s }.include?("id")
        raise ArgumentError, "find_each: only_columns must include id"
      end
      quoted_table = '"' + table_name + '"'
      base_clause = nil
      base_values = []
      unless conditions.nil?
        pair = where_clause_values(conditions)
        base_clause = pair[0]
        base_values = pair[1]
      end
      cursor = nil
      while true
        sql = "SELECT " + projection + " FROM " + quoted_table
        predicate = base_clause
        values = []
        base_values.each { |value| values << value }
        unless cursor.nil?
          cursor_predicate = '"id" > ?'
          predicate = predicate.nil? ? cursor_predicate : predicate + " AND " + cursor_predicate
          values << cursor
        end
        sql += " WHERE " + predicate unless predicate.nil?
        sql += ' ORDER BY "id" ASC LIMIT ?'
        values << batch_size
        rows = rows_by_sql(sql, values)
        break if rows.empty?
        rows.each do |row|
          row_id = row["id"]
          if row_id.nil?
            raise ArgumentError, "find_each: the projection must include id"
          end
          cursor = row_id
          yield from_row(row)
        end
        break if rows.length < batch_size
      end
    end

    # Yields every row matching the conditions as an array of records, in `id`
    # order, so one bulk statement can cover each batch. The conditions,
    # `batch_size`, cursor, snapshot, and `break` contracts are the same as
    # `find_each`; the memory bound is the batch size, not the table. Empty
    # batches are never yielded; the final shorter batch is.
    #
    # @param conditions [Hash{Symbol => Object}, nil] the `where_clause`
    #   conditions contract, with values bound; nil means the whole table and
    #   an empty hash raises (a broken condition builder must not widen into a
    #   full read)
    # @param batch_size [Integer] how many rows one query reads; must be
    #   positive
    # @return [void]
    # @raise [ArgumentError] the block is missing; the conditions hash is
    #   empty; `batch_size` is not a positive Integer; or `only_columns` omits
    #   `id` (the cursor column)
    # @raise [Sqlx::CastError] a String condition value on a column declared in
    #   `integer_columns` is not a decimal integer
    # @raise [NotImplementedError] the model has not declared
    #   `table_name` / `only_columns` (the declaration stubs raise)
    # @example one bulk update per batch
    #   Model.find_in_batches({ status: 0 }, batch_size: 500) do |records|
    #     Model.update_all!({ id: records.map { |record| record.id } }, { status: 1 })
    #   end
    def find_in_batches(conditions = nil, batch_size: 1000)
      unless block_given?
        raise ArgumentError, "find_in_batches: block required"
      end
      unless batch_size.is_a?(Integer) && batch_size > 0
        raise ArgumentError, "find_in_batches: batch_size must be a positive Integer"
      end
      if !conditions.nil? && conditions.empty?
        raise ArgumentError, "find_in_batches: conditions must not be an empty hash — pass nil to read the whole table"
      end
      unless only_columns.map { |column| column.to_s }.include?("id")
        raise ArgumentError, "find_in_batches: only_columns must include id"
      end
      quoted_table = '"' + table_name + '"'
      base_clause = nil
      base_values = []
      unless conditions.nil?
        pair = where_clause_values(conditions)
        base_clause = pair[0]
        base_values = pair[1]
      end
      cursor = nil
      while true
        sql = "SELECT " + projection + " FROM " + quoted_table
        predicate = base_clause
        values = []
        base_values.each { |value| values << value }
        unless cursor.nil?
          cursor_predicate = '"id" > ?'
          predicate = predicate.nil? ? cursor_predicate : predicate + " AND " + cursor_predicate
          values << cursor
        end
        sql += " WHERE " + predicate unless predicate.nil?
        sql += ' ORDER BY "id" ASC LIMIT ?'
        values << batch_size
        rows = rows_by_sql(sql, values)
        break if rows.empty?
        records = []
        rows.each do |row|
          row_id = row["id"]
          if row_id.nil?
            raise ArgumentError, "find_in_batches: the projection must include id"
          end
          cursor = row_id
          records << from_row(row)
        end
        yield records
        break if rows.length < batch_size
      end
    end

    # Returns the row with this `id`, or raises `Sqlx::RecordNotFound` when no
    # row has it. The lookup column is `id` by decision: every table this entry
    # serves has an `id` primary key, and a table without one does not use
    # `find`. Built on `find_by`, so the conditions contract and the
    # declaration pair apply, and the message names the table and the id that
    # missed.
    #
    # @param id [Integer, String] the `id` column value to match — bound as a
    #   condition value like any other
    # @return [Object] the matching record — never nil
    # @raise [Sqlx::RecordNotFound] no row has that `id`
    # @raise [Sqlx::CastError] the model declares `id` in `integer_columns` and
    #   the String id is not a decimal integer
    # @raise [NotImplementedError] the model has not declared
    #   `table_name` / `only_columns` (through `find_by`)
    # @example
    #   User.find(42)
    def find(id)
      record = find_by({ id: id })
      if record.nil?
        raise Sqlx::RecordNotFound, "Couldn't find #{table_name} with id=#{id.inspect}"
      end
      record
    end

    # Returns how many rows match the conditions; no argument counts the whole
    # table. An empty table answers 0: a count is a number, so there is no miss
    # to raise on. `only_columns` is not needed — COUNT(*) reads no column.
    #
    # @param conditions [Hash{Symbol => Object}] the `where_clause` conditions
    #   contract, with values bound; an empty hash (or no argument) counts the
    #   whole table
    # @return [Integer] the number of matching rows — 0 when none match
    # @raise [Sqlx::CastError] a String value on a column declared in
    #   `integer_columns` is not a decimal integer
    # @raise [NotImplementedError] the model has not declared `table_name`
    #   (the declaration stub raises)
    # @example
    #   ApiSetting.count
    #   # => 42
    #   ApiSetting.count({ verified: 1 })
    #   # => 7
    def count(conditions = {})
      sql = 'SELECT COUNT(*) AS total FROM "' + table_name + '"'
      values = []
      unless conditions.empty?
        pair = where_clause_values(conditions)
        sql += " WHERE " + pair[0]
        values = pair[1]
      end
      rows = Sqlx::Database.exec_read(sql, values)
      rows.empty? ? 0 : rows[0]["total"].to_i
    end

    # Returns whether a matching row exists, from `SELECT 1 ... LIMIT 1`,
    # without building a record. The input has four forms: no argument (or an
    # empty hash) asks whether the table has any row at all; a conditions hash
    # applies the `where_clause` contract; a scalar is shorthand for
    # `{ id: value }`, the same `id` lookup `find` uses; nil or false answers
    # false without running a query.
    #
    # An empty hash is well-defined here, unlike `find_by({})`: "does any row
    # exist?" is a question, "which row?" is not.
    #
    # @param conditions [Hash{Symbol => Object}, Integer, String, nil] the
    #   conditions as above — a Hash follows the `where_clause` contract with
    #   values bound, a scalar matches the `id` column
    # @return [Boolean] true when one matching row exists
    # @raise [Sqlx::CastError] a String value on a column declared in
    #   `integer_columns` is not a decimal integer
    # @raise [NotImplementedError] the model has not declared `table_name`
    # @example
    #   ApiSetting.exists?({ key: "flag" })  # conditions hash
    #   User.exists?(user_id)                # id shorthand
    #   Invoice.exists?                      # any row?
    def exists?(conditions = {})
      return false unless conditions
      conditions = { id: conditions } unless conditions.is_a?(Hash)
      sql = 'SELECT 1 FROM "' + table_name + '"'
      values = []
      unless conditions.empty?
        pair = where_clause_values(conditions)
        sql += " WHERE " + pair[0]
        values = pair[1]
      end
      exists_by_sql(sql + " LIMIT 1", values)
    end

    # Inserts one row from a column/value hash and returns the stored record,
    # re-read by its `id`. The INSERT covers exactly the columns the caller
    # passed plus the declared timestamps it left out, so a table without
    # timestamp columns needs no opt-out. The id comes from the INSERT's own
    # RETURNING row, so a concurrent session cannot answer with its own id; the
    # table must carry the `id` column the re-read uses.
    #
    # Input conversion stays with the caller. This layer binds the values it is
    # given and runs no validation: a schema constraint is the validation here,
    # and it reaches the caller as an exception — a UNIQUE violation raises
    # `Sqlx::RecordNotUnique`, and other constraint failures surface as the
    # adapter's driver error. Keys are code, not input: an unknown column
    # surfaces as a SQL error.
    #
    # @param attrs [Hash{Symbol => Object}] column => value. A declared
    #   `created_at`/`updated_at` the caller did not pass is filled with the
    #   current UTC time — one value shared by both columns, so an insert's two
    #   timestamps agree. A timestamp the caller passed wins.
    # @return [Object] the stored record, re-read by its `id` — never nil (the
    #   row was just written)
    # @raise [ArgumentError] empty attrs — there is no row and no columns to
    #   insert
    # @raise [NotImplementedError] the model has not declared
    #   `table_name` / `only_columns` (the declaration stubs raise)
    # @raise [Sqlx::RecordNotUnique] a UNIQUE constraint rejects the insert
    # @example
    #   Post.create!({ title: "hello", body: "world" })
    def create!(attrs)
      raise ArgumentError, "create!: attrs must not be empty" if attrs.empty?
      declared = only_columns.map { |column| column.to_s }
      columns = []
      placeholders = []
      values = []
      given = []
      attrs.each do |key, value|
        name = key.to_s
        given << name
        columns << '"' + name + '"'
        placeholders << "?"
        values << bound_value(name, value)
      end
      timestamp_columns = []
      [ "created_at", "updated_at" ].each do |timestamp_column|
        next unless declared.include?(timestamp_column)
        next if given.include?(timestamp_column)
        timestamp_columns << timestamp_column
      end
      if !timestamp_columns.empty?
        now = Time.now.utc
        timestamp_columns.each do |timestamp_column|
          columns << '"' + timestamp_column + '"'
          placeholders << "?"
          values << now
        end
      end
      sql = 'INSERT INTO "' + table_name + '" (' + columns.join(", ") +
            ") VALUES (" + placeholders.join(", ") + ') RETURNING "id"'
      rows = write(sql, values)
      find(rows[0]["id"])
    end

    # Rewrites the columns of the row with this `id` and returns the re-read
    # record. A class method because this runtime writes through class-level
    # SQL: there is no instance `save`. An unknown id writes nothing, and the
    # re-read then raises `Sqlx::RecordNotFound`, so a missing row never looks
    # like a successful write. A declared `updated_at` the caller left out is
    # set to the current UTC time; `created_at` is never touched. Same key rule
    # as `create!`: code, not input, an unknown column surfaces as a SQL error.
    #
    # @param id [Integer, String] the `id` of the row to rewrite — the same
    #   `id` column `find` looks up
    # @param attrs [Hash{Symbol => Object}] column => value, the `create!`
    #   binding contract; a passed `updated_at` wins over the automatic one.
    # @return [Object] the re-read record — never nil on success
    # @raise [ArgumentError] empty attrs — there is nothing to rewrite
    #   (timestamp-only writes belong to a dedicated entry, not this one)
    # @raise [Sqlx::RecordNotFound] no row has that `id`
    # @raise [Sqlx::CastError] the model declares `id` in `integer_columns` and
    #   the String id is not a decimal integer
    # @raise [NotImplementedError] the model has not declared
    #   `table_name` / `only_columns` (the declaration stubs raise)
    # @example
    #   Post.update!(42, { title: "revised" })
    def update!(id, attrs)
      raise ArgumentError, "update!: attrs must not be empty" if attrs.empty?
      id = cast_id(id)
      declared = only_columns.map { |column| column.to_s }
      sets = []
      values = []
      given = []
      attrs.each do |key, value|
        name = key.to_s
        given << name
        sets << '"' + name + '" = ?'
        values << bound_value(name, value)
      end
      if declared.include?("updated_at") && !given.include?("updated_at")
        sets << '"updated_at" = ?'
        values << Time.now.utc
      end
      values << id
      quoted_table = '"' + table_name + '"'
      write('UPDATE ' + quoted_table + ' SET ' + sets.join(", ") +
            ' WHERE "id" = ?', values)
      find(id)
    end

    # Rewrites every row matching the conditions and returns how many rows
    # changed. `update!` is the single-row form; `delete_all!` takes the same
    # conditions and returns the same count. nil conditions mean the whole
    # table; an empty hash raises, the same rule `fetch_many` keeps.
    #
    # No timestamp is set: `update!` sets `updated_at` because it returns a
    # re-read record, while a batch rewrite moves a timestamp only when the
    # caller passes one.
    #
    # @param conditions [Hash{Symbol => Object}, nil] the `where_clause`
    #   conditions contract, with values bound; nil means the whole table (no
    #   WHERE clause at all)
    # @param attrs [Hash{Symbol => Object}] column => value, the `create!`
    #   binding contract for the SET half. Keys are code: an unknown column is a
    #   SQL error.
    # @return [Integer] the number of rows changed — 0 when no row matched
    # @raise [ArgumentError] an empty conditions hash — the whole-table rewrite
    #   is spelled nil, so an empty hash means the condition builder broke; or
    #   empty attrs (nothing to rewrite)
    # @raise [Sqlx::CastError] a String condition value on a column declared in
    #   `integer_columns` is not a decimal integer
    # @raise [NotImplementedError] the model has not declared `table_name`
    # @example
    #   Post.update_all!({ status: "stale", created_at: { lt: cutoff } }, { status: "archived" })
    #   # => 7
    #   Post.update_all!(nil, { status: "archived" })
    #   # => every row
    def update_all!(conditions, attrs)
      if !conditions.nil? && conditions.empty?
        raise ArgumentError, "update_all!: conditions must not be an empty hash — pass nil to rewrite the whole table"
      end
      raise ArgumentError, "update_all!: attrs must not be empty" if attrs.empty?
      sets = []
      values = []
      attrs.each do |key, value|
        name = key.to_s
        sets << '"' + name + '" = ?'
        values << bound_value(name, value)
      end
      sql = 'UPDATE "' + table_name + '" SET ' + sets.join(", ")
      condition_values = []
      unless conditions.nil?
        pair = where_clause_values(conditions)
        sql += " WHERE " + pair[0]
        condition_values = pair[1]
      end
      condition_values.each { |value| values << value }
      Sqlx::Database.exec_write(sql, values)["count"]
    end

    # Inserts rows and rewrites the row a conflict collides with, in one
    # statement — the bulk form for a table whose identity is a unique index,
    # not a primary key. The conflict target is required (`unique_by:`): this
    # runtime does not read the schema. A conflict on another unique index is
    # not this statement's business and raises `Sqlx::RecordNotUnique`, so a
    # wrong target cannot quietly rewrite the wrong rows.
    #
    # The updated columns are the row keys minus `unique_by:`. No timestamp is
    # set, as in `update_all!`. One call builds one statement; a batch larger
    # than the driver's bound-value limit is the caller's to chunk.
    #
    # @param rows [Array[Hash{Symbol => Object}]] one hash per row to insert.
    #   Every row must have the same keys — a batch is one column list.
    # @param unique_by [Array[Symbol, String]] the columns of the unique index
    #   that defines the same row — code, not input; every column must be among
    #   the row keys (a conflict target outside the insert list would never
    #   fire)
    # @return [Integer] the number of rows inserted or rewritten
    # @raise [ArgumentError] empty rows, an empty `unique_by`, rows with
    #   differing keys, a `unique_by` column outside the row keys, or no column
    #   left to update (every key part of `unique_by` — a skip-duplicates
    #   statement is not this entry)
    # @raise [Sqlx::RecordNotUnique] another unique index on the table rejects a
    #   row
    # @raise [NotImplementedError] the model has not declared `table_name`
    # @example
    #   Widget.upsert_all!([{ name: "a", value: 1.0 }, { name: "b", value: 2.0 }], unique_by: [ :name ])
    #   # => 2
    def upsert_all!(rows, unique_by:)
      raise ArgumentError, "upsert_all!: rows must not be empty" if rows.empty?
      raise ArgumentError, "upsert_all!: unique_by must not be empty" if unique_by.empty?
      quoted_table = '"' + table_name + '"'
      entries = []
      rows.each do |row|
        entry = {}
        row.each { |key, value| entry[key.to_s] = value }
        entries << entry
      end
      keys = entries.first.keys
      entries.each do |entry|
        if entry.keys.sort != keys.sort
          raise ArgumentError, "upsert_all!: all rows must have the same keys"
        end
      end
      conflict = []
      unique_by.each do |column|
        name = column.to_s
        unless keys.include?(name)
          raise ArgumentError, "upsert_all!: unique_by column #{name} is not among the row keys"
        end
        conflict << '"' + name + '"'
      end
      updatable = keys.reject { |name| unique_by.map { |column| column.to_s }.include?(name) }
      if updatable.empty?
        raise ArgumentError, "upsert_all!: no column left to update — every row key is part of unique_by"
      end
      columns = keys.map { |name| '"' + name + '"' }.join(", ")
      sets = updatable.map { |name| '"' + name + '" = excluded."' + name + '"' }.join(", ")
      tuples = []
      values = []
      entries.each do |entry|
        tuples << "(" + keys.map { "?" }.join(", ") + ")"
        keys.each { |name| values << bound_value(name, entry[name]) }
      end
      Sqlx::Database.exec_write('INSERT INTO ' + quoted_table + ' (' + columns + ") VALUES " + tuples.join(", ") +
                                " ON CONFLICT (" + conflict.join(", ") + ") DO UPDATE SET " + sets, values)["count"]
    end

    # Deletes the row with this `id` and returns the number of rows deleted — 0
    # when no row had that id. The trailing bang follows `create!`/`update!` by
    # naming convention, not a promise to raise on a miss: the caller's lookup
    # already decided whether a missing row is a 404. The column is `id` by the
    # same decision `find` makes.
    #
    # @param id [Integer, String] the `id` column value to match
    # @return [Integer] the number of rows deleted — 0 when no row had that
    #   `id`
    # @raise [ArgumentError] the id is neither an Integer nor a String — an
    #   Array is the form `delete_all!({ id: ids })` owns, and anything else
    #   would bind as text and miss silently on one adapter while the driver
    #   errors on the other
    # @raise [Sqlx::CastError] the model declares `id` in `integer_columns` and
    #   the String id is not a decimal integer
    # @raise [NotImplementedError] the model has not declared `table_name`
    # @example
    #   Post.delete!(42)
    #   # => 1
    def delete!(id)
      unless id.is_a?(Integer) || id.is_a?(String)
        raise ArgumentError, "delete!: id must be an Integer or String — pass many ids to delete_all!({ id: [...] })"
      end
      id = cast_id(id)
      Sqlx::Database.exec_write('DELETE FROM "' + table_name + '" WHERE "id" = ?', [ id ])["count"]
    end

    # Deletes every row matching the conditions and returns how many rows went.
    # `delete!` is the single-row form; nil conditions mean the whole table, and
    # an empty hash raises — the same rule `update_all!` keeps.
    #
    # @param conditions [Hash{Symbol => Object}, nil] the `where_clause`
    #   conditions contract, with values bound; nil means the whole table (no
    #   WHERE clause at all)
    # @return [Integer] the number of rows deleted — 0 when no row matched
    # @raise [ArgumentError] an empty conditions hash — the whole-table DELETE
    #   is spelled nil, so an empty hash means the condition builder broke; or
    #   a conditions value the `where_clause` contract rejects
    # @raise [Sqlx::CastError] a String condition value on a column declared in
    #   `integer_columns` is not a decimal integer
    # @raise [NotImplementedError] the model has not declared `table_name`
    # @example
    #   Comment.delete_all!({ post_id: 42 })
    #   # => 3
    #   Comment.delete_all!(nil)
    #   # => every row
    def delete_all!(conditions)
      if !conditions.nil? && conditions.empty?
        raise ArgumentError, "delete_all!: conditions must not be an empty hash — pass nil to delete the whole table"
      end
      sql = 'DELETE FROM "' + table_name + '"'
      values = []
      unless conditions.nil?
        pair = where_clause_values(conditions)
        sql += " WHERE " + pair[0]
        values = pair[1]
      end
      Sqlx::Database.exec_write(sql, values)["count"]
    end

    # the single-row half of `find_by_sql`: runs the caller's SELECT and
    # returns the first row as a record, or nil when it returns no row.
    # `find_by` assembles its `... LIMIT 1` statement on this method, so the
    # single-row read shares one path with `find_by_sql`. The statement is read
    # in full, so a caller that wants one row of a large set bounds it with
    # `LIMIT`.
    #
    # Private on purpose: the supported single-row entries are `find_by`
    # (conditions, with `order:`) and `find_by_sql(...).first` (caller SQL);
    # this half is the assembly between them and may change without notice.
    def one_by_sql(sql, values = nil)
      rows = rows_by_sql(sql, values)
      if rows.empty?
        nil
      else
        from_row(rows[0])
      end
    end

    # the existence half: runs the caller's SELECT and returns whether it
    # returned any row, without building a record. `exists?` assembles its
    # `SELECT 1 ... LIMIT 1` statement on this method.
    #
    # Private on purpose: `exists?` is the supported existence entry and
    # `row_by_sql` the raw single-row read; this half is the assembly
    # between them and may change without notice.
    def exists_by_sql(sql, values = nil)
      bound = values_for_placeholders(sql, values)
      !Sqlx::Database.exec_read(sql, bound).empty?
    end

    # The bind companion of `where_clause`: the same conditions contract with
    # every value replaced by a `?` placeholder and returned alongside the
    # clause. Core entries use it; `where_clause` keeps the literal form for
    # caller-written SQL.
    #
    # @param conditions [Hash{Symbol => Object}] the `where_clause`
    #   conditions contract
    # @return [Array] the clause body and one value per placeholder, in
    #   statement order
    # @raise [ArgumentError] on an empty conditions hash or the
    #   `where_clause` value contract
    def where_clause_values(conditions)
      raise ArgumentError, "where_clause: conditions must not be empty" if conditions.empty?
      parts = []
      values = []
      conditions.each do |key, value|
        pair = condition_predicate(key.to_s, value, true)
        parts << pair[0]
        values.concat(pair[1])
      end
      [parts.join(" AND "), values]
    end

    # One condition as its predicate and the values that predicate binds.
    # `bind` picks the form: true emits `?` placeholders for the query entries,
    # false renders through `Sqlx.quote` for `where_clause`. Both forms run the
    # same validation, so a malformed condition fails identically whichever
    # entry the caller uses.
    #
    # @param column [String] the condition's column name
    # @param value [Object] the condition value in the `where_clause` contract
    # @param bind [Boolean] true to emit placeholders, false to inline values
    # @return [Array] the predicate and the values it binds (empty when inline)
    # @raise [ArgumentError] the value violates the conditions contract
    def condition_predicate(column, value, bind)
      if value.nil?
        [column + " IS NULL", []]
      elsif value.is_a?(Array)
        raise ArgumentError, "where_clause: #{column} array must not be empty" if value.empty?
        elements = []
        bound = []
        value.each do |element|
          if element.nil?
            raise ArgumentError, "where_clause: #{column} array must not carry nil"
          end
          if element.is_a?(Hash)
            raise ArgumentError, "where_clause: #{column} array must not carry an operator hash — a condition is a key of its own"
          end
          if bind
            elements << "?"
            bound << cast_integer_value(column, element)
          else
            elements << Sqlx.quote(element)
          end
        end
        [column + " IN (" + elements.join(", ") + ")", bound]
      elsif value.is_a?(Hash)
        operator_predicates(column, value, bind)
      elsif bind
        [column + " = ?", [ cast_integer_value(column, value) ]]
      else
        [column + " = " + Sqlx.quote(value), []]
      end
    end

    # The predicates for one operator-hash condition value:
    # `column <op> <bound>` per whitelisted comparison (`lt`/`lte`/`gt`/`gte`)
    # plus the null test (`is_not: nil` → `column IS NOT NULL`). With `bind`
    # true each comparison bound becomes a `?` placeholder and its value is
    # returned; with false the bound is rendered through `Sqlx.quote`.
    #
    # The whitelist and the bound checks are the entry validation: an unknown
    # operator raises instead of rendering a predicate nobody meant, an empty
    # hash raises instead of dropping the condition silently, a nil or
    # structured comparison bound raises (`< NULL` matches nothing; a nested
    # Hash would stringify), and `is_not` with any bound but nil raises because
    # SQL's `IS NOT` is the null test here, not a general negation.
    #
    # @param column [String] the condition's column name
    # @param operators [Hash{Symbol => Object}] the operator predicates
    # @param bind [Boolean] true to emit placeholders, false to inline values
    # @return [Array] the joined predicates and the values they bind
    # @raise [ArgumentError] an empty operator hash, an unknown operator, or
    #   an invalid bound
    def operator_predicates(column, operators, bind)
      raise ArgumentError, "where_clause: #{column} operator hash must not be empty" if operators.empty?
      predicates = []
      values = []
      operators.each do |operator, bound|
        if operator == :is_not
          if !bound.nil?
            raise ArgumentError, "where_clause: #{column} is_not bound must be nil — the operator is the null test (IS NOT NULL)"
          end
          predicates << (column + " IS NOT NULL")
          next
        end
        operator_sql = case operator
                       when :lt then "<"
                       when :lte then "<="
                       when :gt then ">"
                       when :gte then ">="
                       else
                         raise ArgumentError, "where_clause: #{column} has no operator #{operator.inspect}"
                       end
        if bound.nil?
          raise ArgumentError, "where_clause: #{column} #{operator.inspect} bound must not be nil"
        end
        if bound.is_a?(Hash) || bound.is_a?(Array)
          raise ArgumentError, "where_clause: #{column} #{operator.inspect} bound must be a value"
        end
        if bind
          predicates << (column + " " + operator_sql + " ?")
          values << cast_integer_value(column, bound)
        else
          predicates << (column + " " + operator_sql + " " + Sqlx.quote(bound))
        end
      end
      [predicates.join(" AND "), values]
    end

    # one column's bound value: a declared json column serializes through
    # `Sqlx::Json` (nil is SQL NULL), any other column binds the value unchanged
    # so the adapter renders it by runtime type. This is why a caller hands a
    # write entry a logical Hash and never calls the codec itself. A declared
    # value JSON cannot represent raises here — the codec's contract, so a Time
    # never reaches the column as text. The loop normalizes each name the way
    # `from_row` does, so a Symbol list stays correct rather than silently
    # skipping the column.
    def bound_value(column, value)
      names = json_columns.map { |name| name.to_s }
      if names.include?(column)
        Sqlx::Json.encode(value)
      else
        value
      end
    end

    # One condition value cast for the columns declared in
    # `integer_columns`: an Integer passes, a decimal String becomes an
    # Integer, and anything else is a contract failure. The cast is strict on
    # purpose — "1-welcome" and "1.0" must not silently become 1.
    def cast_integer_value(column, value)
      return value unless integer_column?(column)
      if value.is_a?(Integer)
        return value
      end
      if value.is_a?(String) && decimal_integer_string?(value)
        return value.to_i
      end
      raise Sqlx::CastError, "cannot cast #{value.inspect} to Integer for #{table_name}.#{column}"
    end

    # Is `column` declared in the model's integer list? The list may carry
    # Strings or Symbols; compare both sides as Strings without allocating a
    # normalized copy per condition. A column declared as another logical
    # type (boolean, datetime, date, json) keeps that type: a schema INTEGER
    # can back a boolean or json scalar, and the model's exception list is
    # the authority for the condition value.
    def integer_column?(column)
      return false if list_includes?(boolean_columns, column)
      return false if list_includes?(datetime_columns, column)
      return false if list_includes?(date_columns, column)
      return false if list_includes?(json_columns, column)
      list_includes?(integer_columns, column)
    end

    # A linear membership test over a declaration list; names may be Strings
    # or Symbols, so both sides compare as Strings.
    def list_includes?(names, column)
      i = 0
      while i < names.length
        return true if names[i].to_s == column
        i = i + 1
      end
      false
    end

    # A decimal integer string with an optional sign: digits only, no
    # whitespace, underscores, or hex. "1-welcome" and "1.0" are not integers.
    def decimal_integer_string?(text)
      return false if text.empty?
      start = 0
      first = text[0, 1]
      if first == "-" || first == "+"
        start = 1
      end
      return false if start >= text.length
      i = start
      while i < text.length
        c = text[i, 1]
        return false if c < "0" || c > "9"
        i = i + 1
      end
      true
    end

    # The id path used by `update!` and `delete!`: apply the same integer cast
    # as a condition on `id`. A model without an integer id returns the value
    # unchanged.
    def cast_id(id)
      cast_integer_value("id", id)
    end

    # the caller's value list as an Array, checked against the statement's `?`
    # count. A missing value would bind NULL and a surplus one would be dropped,
    # both quiet, so every entry that takes values checks here.
    def values_for_placeholders(sql, values)
      bound = values.nil? ? [] : values
      placeholders = placeholder_count(sql)
      if placeholders != bound.length
        raise ArgumentError, "placeholder/value count mismatch: " + placeholders.to_s + " placeholders, " + bound.length.to_s + " values — sql: " + sql
      end
      bound
    end

    # the statement's placeholder count. It backs every value-taking entry
    # (`rows_by_sql`, `exists_by_sql`, `write`) so the values can be checked
    # against them. An app calls those entries, never this — private on purpose,
    # free to change or vanish without notice.
    def placeholder_count(sql)
      count = 0
      in_str = false
      i = 0
      while i < sql.length
        c = sql[i, 1]
        if in_str
          if c == "'"
            if sql[i + 1, 1] == "'"
              i = i + 1
            else
              in_str = false
            end
          end
        elsif c == "'"
          in_str = true
        elsif c == "?"
          count = count + 1
        end
        i = i + 1
      end
      count
    end

    # `private :a, :b` (not `private_class_method`): these are the module's
    # instance methods, which `extend` turns into the base's class methods —
    # so the instance-level privacy is the one that travels. Explicit names
    # keep a later public method from being captured by a trailing keyword.
    # The two read halves are internal too: `find_by` assembles on
    # `one_by_sql`, `exists?` on `exists_by_sql`, and the supported entries
    # are the public methods above — `find_by_sql` included, for joins and
    # other caller-written SQL.
    private :one_by_sql, :exists_by_sql, :where_clause_values, :condition_predicate, :operator_predicates, :values_for_placeholders, :placeholder_count, :bound_value, :cast_integer_value, :integer_column?, :list_includes?, :decimal_integer_string?, :cast_id
  end
end
