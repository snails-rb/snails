module Sqlx
  # The query surface — every class-side entry point that runs or
  # assembles SQL. Extended onto Base so each method arrives as a
  # model class method; the bodies reach the declaration surface
  # (Model) through the same receiver.
  module Query
    # the escape hatch for a caller-written SELECT: this walks the statement and
    # hands back this model's records. It exists so an association reader on the
    # owning model carries only its own SQL (column list, join, foreign key)
    # instead of the prepare/step/finalize dance every reader repeated. The
    # per-column read stays in the model's `from_row`, which receives one
    # name-keyed row per statement row — the same shape the raw read
    # (`rows_by_sql`) answers with — so the caller's column order never binds
    # hydration: a reordered SELECT still lands every value on its own
    # attribute.
    #
    # The walk specializes per concrete receiver — the receiver's
    # `from_row` fixes the element — so a caller may declare
    # `-> Array[<Model>]` across classes and the declaration holds.
    # No per-model hydration wrapper exists for typing.
    #
    # A value enters the statement by binding, the way it enters a
    # write: the values list is the one way in, and a value spliced
    # into the statement's text is the caller's own escaping.
    #
    # @param sql [String] the caller's SELECT, with a `?` for each value
    # @param values [Array, nil] one value per `?` — nil for a
    #   statement that takes none
    # @return [Array] one record per row, mapped by the receiver's `from_row`
    # @raise [ArgumentError] the values and the statement's
    #   placeholders do not agree
    # @example typed association reader — declaration and walk agree
    #   # rbs: def subscriptions: () -> Array[Subscription]
    #   def subscriptions
    #     Subscription.find_by_sql("SELECT " + Subscription.projection +
    #       " FROM subscriptions WHERE user_id = ?", [ @id ])
    #   end
    def find_by_sql(sql, values = nil)
      rows_by_sql(sql, values).map { |row| from_row(row) }
    end

    # the single-row half of `rows_by_sql`: walk the caller's SELECT and hand
    # back the row it yields first, keyed by column name, or nil when it yields
    # none. It is the raw counterpart of the model-level single-row read
    # (`find_by_sql(...).first`): the same query, without the hydration: the row
    # shape is dynamic (a view, an aggregate, a computed column), so no model
    # stands behind it.
    #
    # @param sql [String] the caller's SELECT, with a `?` for each value
    # @param values [Array, nil] one value per `?` — nil for a
    #   statement that takes none
    # @return [Hash{String => Object}] the first row, keyed by column
    #   name — nil when the statement yielded no row
    # @raise [ArgumentError] the values and the statement's
    #   placeholders do not agree
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

    # the raw-read half of the read family: walk the caller's SELECT and hand
    # back each row as a name→value Hash, without hydrating a record. It exists
    # for the statements no model can stand behind — a view, an aggregate, a
    # computed column — where the row shape is genuinely dynamic and a model
    # would be a lie. `find_by_sql` is the same walk with a model in front of
    # it; this one keeps the dynamic shape honest, and the shape is shared —
    # `from_row` receives exactly these name-keyed rows.
    #
    # A value enters a read the way it enters a write: bound. The
    # statement's placeholders and the values must agree — a missing
    # value would bind NULL and a surplus one would be dropped, both
    # quiet — so this entry checks and says so, the way `write` does.
    #
    # @param sql [String] the caller's SELECT, with a `?` for each value
    # @param values [Array, nil] one value per `?` — nil for a
    #   statement that takes none. Within the list, nil binds NULL and
    #   a Time binds in the runtime's stored form (UTC)
    # @return [Array] one Hash per row, keyed by column name — an empty
    #   array when the statement yields no rows (never nil). Values are
    #   the adapter's native types (Integer/Float/String, nil for NULL)
    # @raise [ArgumentError] the values and the statement's
    #   placeholders do not agree
    # @example view read — no model fits the row shape
    #   Sqlx::Base.rows_by_sql("SELECT service, host FROM latest_samples")
    # @example a read with a value — bound, not spliced into the text
    #   Sqlx::Base.rows_by_sql("SELECT id FROM widgets WHERE name = ?", [ "alpha" ])
    def rows_by_sql(sql, values = nil)
      bound = values_for_placeholders(sql, values)
      Sqlx::Database.exec_read(sql, bound)
    end

    # the parameterized-write half of the raw SQL surface: run the caller's
    # INSERT/UPDATE/DELETE with raw Ruby values bound to each `?`. The adapter
    # renders each value by its runtime type, so callers never inline literals.
    # "Write" is the DB-side counterpart of the read entries (reads SELECT,
    # writes change rows). A class-level entry so models call it where
    # `find_by_sql` lives; instance writers name the receiver explicitly.
    # Delegates to adapter-owned `Sqlx::Database.exec_write`.
    #
    # The return is what the statement returned — the rows it
    # produced, keyed by column name. A statement that returns
    # nothing returns an empty array; a `RETURNING` statement returns
    # one row per row it changed, which is how a caller learns which
    # row a write took (a queue claim picks one and needs it back).
    #
    # "How many rows changed?" is a question about a table, so it
    # belongs to the model layer (`count`, `delete_all!`) — the raw
    # write answers what the statement returned.
    #
    # A Time is stored in the runtime's stored form — UTC, whatever
    # zone the caller handed over — so a caller never formats a time
    # to store one.
    #
    # A value enters a statement only by binding: the values list is
    # the one way in, and the adapter renders each value by its runtime
    # type. A value spliced into the SQL text is the caller's own
    # escaping — the thing this surface exists to remove.
    #
    # The statement's placeholders and the values must agree: a
    # missing value would bind NULL and a surplus one would be
    # dropped, both quiet — so this entry checks and says so. The
    # check is here, at the surface that promises the binding, and
    # not in the adapter below (a caller that wants the adapter's own
    # behavior still has it).
    #
    # @param sql [String] the caller's INSERT/UPDATE/DELETE, with a
    #   `?` for each value
    # @param values [Array, nil] one value per `?` — nil for a
    #   statement that takes none. nil binds NULL, a Time binds in the
    #   runtime's stored form (UTC), everything else by its runtime
    #   type
    # @return [Array] one name-keyed row per row the statement
    #   returned — an empty array when it returned none
    # @raise [ArgumentError] the values and the statement's
    #   placeholders do not agree
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

    # the WHERE clause body for a conditions hash: one predicate per column,
    # joined with AND. The assembly half that `find_by` is built on. Core owns
    # it because the translation never varies by model (the table lives in the
    # caller's SELECT) — a hand-rolled private copy is where a nil condition
    # silently becomes `= ''` and stops matching `IS NULL` rows. An Array value
    # is membership on the column (`IN (...)`), so a status-set filter rides the
    # same conditions contract instead of escaping to raw SQL. An operator hash
    # value is a predicate bag on the column: a range comparison (`{ lt: cutoff
    # }`) so a cutoff filter rides the same contract without a Range object
    # (which this runtime cannot build over a Time), and the null test (`{
    # is_not: nil }`) so "this column has a value" reads as the SQL it renders —
    # `col IS NOT NULL`, the has-value side of nil's `IS NULL`.
    #
    # @param conditions [Hash{Symbol => Object}] column Symbol =>
    #   value. nil means `IS NULL` on that column; an Array means
    #   membership on it — one `IN (...)` list, each element
    #   translated by the same per-type rules as equality below; a
    #   Hash means predicates on it — one per whitelisted operator:
    #   comparisons (`:lt` `<`, `:lte` `<=`, `:gt` `>`, `:gte` `>=`)
    #   with a value bound rendered like equality, and the null test
    #   (`:is_not => nil`, rendered `IS NOT NULL`); anything else
    #   means equality on it, rendered through `Sqlx.quote` — values
    #   are data (they arrive from request params) and are never
    #   interpolated raw. Keys are code, not input, and are not
    #   validated: an unknown column surfaces as a loud SQL error from
    #   the driver.
    # @return [String] the clause body — no `WHERE` keyword, ready
    #   to splice into the caller's SELECT
    # @raise [ArgumentError] on an empty hash — there is no clause
    #   to build, so no WHERE-less SELECT either; on an empty Array
    #   value — `IN ()` is not SQL, and an empty set deserves the
    #   same loud treatment as an empty hash; on an Array carrying
    #   nil — `IN (NULL, ...)` answers UNKNOWN for every row, so the
    #   null test must be a key of its own; on an Array carrying a
    #   Hash — `IN (...)` takes values, not predicates; on an
    #   operator hash that is empty (no predicate to build — the
    #   condition would vanish silently), names an operator outside
    #   the whitelist (a typo must fail loud, not render a predicate
    #   nobody meant), carries a nil or structured comparison bound
    #   (`< NULL` never matches, a nested Hash would stringify into
    #   the comparison), or gives `is_not` a bound other than nil
    #   (`IS NOT <value>` is not SQL — the operator is the null test)
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
        if value.nil?
          parts << (key.to_s + " IS NULL")
        elsif value.is_a?(Array)
          raise ArgumentError, "where_clause: #{key} array must not be empty" if value.empty?
          elements = []
          value.each do |element|
            if element.nil?
              raise ArgumentError, "where_clause: #{key} array must not carry nil"
            end
            if element.is_a?(Hash)
              raise ArgumentError, "where_clause: #{key} array must not carry an operator hash — a condition is a key of its own"
            end
            elements << Sqlx.quote(element)
          end
          parts << (key.to_s + " IN (" + elements.join(", ") + ")")
        elsif value.is_a?(Hash)
          parts.concat(operator_predicates(key.to_s, value))
        else
          parts << (key.to_s + " = " + Sqlx.quote(value))
        end
      end
      parts.join(" AND ")
    end

    # the model's SELECT column list: every declared column, table-qualified and
    # identifier-quoted, comma-joined. Core owns this one assembly so `find_by`
    # and a model's own raw walk build the same spelling — the hand-rolled copy
    # is where quoting drops off and a reserved-word column breaks the parse. A
    # join reader calls another model's projection (`User.projection`) and
    # receives that model's table qualified, so there is no target-table
    # argument: the receiver is always the source of both the table and the
    # column list.
    #
    # @return [String] the qualified column list, ready to splice
    #   after `SELECT`
    # @raise [NotImplementedError] the model has not declared
    #   `table_name` / `only_columns` (the declaration stubs raise)
    # @example
    #   Widget.projection
    #   # => "\"widgets\".\"id\", \"widgets\".\"email\""
    def projection
      quoted_table = '"' + table_name + '"'
      parts = []
      only_columns.each { |column| parts << quoted_table + '."' + column.to_s + '"' }
      parts.join(", ")
    end

    # the single-row lookup by a conditions hash, assembled from the model's
    # `table_name` and `only_columns` declarations. Core owns this shape because
    # it never varies by model (the same
    # `SELECT <quoted cols> FROM <quoted table> WHERE <clause> LIMIT 1` every
    # time) — the hand-rolled per-model copy is where the miss path and the
    # exception message drift. Core quotes the table and column identifiers as
    # it builds them, so reserved words are safe; the condition keys stay
    # unquoted (code, not input — the `where_clause` rule). A model whose lookup
    # needs more (a default scope, a join) overrides this method; a forgotten
    # declaration fails loud through the declaration stubs instead of quietly
    # reading as a miss.
    #
    # The `order:` option decides which matching row arrives instead
    # of leaving it implementation-defined: `:desc` is the match with
    # the highest `id`, `:asc` the lowest. Order with no conditions
    # is a defined question too — `find_by({}, order: :desc)` is the
    # table's last row and `:asc` its first, the answers
    # `Model.last`/`Model.first` give — while an empty hash with no
    # order still has no answer and raises. The order column is `id`
    # by the same decision `find` pins the lookup column: every
    # table this entry point serves is ordered by its primary key,
    # and a different order would be its own declaration decision if
    # a model ever needs it.
    #
    # @param conditions [Hash{Symbol => Object}] column Symbol =>
    #   value. nil means `IS NULL` on that column; an operator hash
    #   carries comparisons (`{ lt: cutoff }`) and the null test
    #   (`{ is_not: nil }` → `IS NOT NULL`); an Array means membership
    #   on it (`IN (...)` — the `where_clause` contract); anything else
    #   means equality on it, rendered through `Sqlx.quote` — values are
    #   data (they arrive from request params) and are never interpolated
    #   raw. Keys are code, not input, and core does not validate them: an
    #   unknown column surfaces as a loud SQL error, never as nil —
    #   a typo'd key must not read as a miss. An empty hash is
    #   allowed only together with `order:` (the table's first/last
    #   row as above).
    # @param order [Symbol, nil] `:desc` or `:asc` — the `id`
    #   direction that picks the row; nil leaves the row
    #   implementation-defined (the pre-order contract)
    # @return [Object, nil] the matching record, or nil on no
    #   match — at most one row; with `order:` the row is the
    #   highest/lowest `id` among the matches
    # @raise [NotImplementedError] the model has not declared
    #   `table_name` / `only_columns` (the declaration stubs raise)
    # @raise [ArgumentError] an empty conditions hash with no
    #   `order:` — there is no clause to build and no row question
    #   to ask; or an `order:` other than `:asc`/`:desc` (a typo
    #   must fail loud, not silently pick a row); or the
    #   `where_clause` value contract — an empty Array value or an
    #   Array carrying nil
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
      sql += " WHERE " + where_clause(conditions) unless conditions.empty?
      sql += ' ORDER BY "id" ' + (order == :asc ? "ASC" : "DESC") unless order.nil?
      one_by_sql(sql + " LIMIT 1")
    end

    # the bang counterpart of `find_by`: no match RAISES instead of returning
    # nil, so an absent record becomes a 404 at the call site instead of a nil
    # that fails somewhere downstream. The message names the declared table —
    # the one identifier core has — rather than a class name it cannot see.
    #
    # @param conditions [Hash{Symbol => Object}] the `find_by`
    #   conditions contract, unchanged.
    # @return [Object] the matching record — never nil
    # @raise [Sqlx::RecordNotFound] no row matches the
    #   conditions
    # @raise [NotImplementedError] the model has not declared
    #   `table_name` / `only_columns`
    # @example
    #   Model.find_by!({ email: "a@example.com" })
    def find_by!(conditions)
      result = find_by(conditions)
      raise Sqlx::RecordNotFound, "Couldn't find " + table_name if result.nil?
      result
    end

    # the multi-row counterpart of `find_by`: every row matching the conditions
    # hash, assembled from the model's `table_name` and `only_columns`
    # declarations. It exists so an association reader or a scope-shaped class
    # method carries only its own conditions instead of hand-writing the same
    # `SELECT <projection> FROM <table> WHERE <clause>` the consumer models
    # repeated per reader — the assembly never varies by model, and the walk
    # rides `find_by_sql`, so the cross-class typed `Array[<Model>]` contract
    # holds at the call site.
    #
    # Unlike `find_by`'s `order:` (which picks one row among the
    # matches), the option here sorts the returned rows: `:desc` is
    # highest id first, `:asc` lowest first. nil conditions mean the
    # whole table: "every row" is an explicit nil the caller writes,
    # never an empty hash — an empty hash is the shape a broken
    # condition builder leaves behind, so it raises instead of quietly
    # widening the read to every row (the same rule `update_all!`·
    # `delete_all!` keep).
    #
    # `limit:` and `offset:` bound the returned window at SQL. They are
    # for a read that wants at most N rows, or a numbered page — not for
    # walking a whole table: an offset page counts the skipped rows
    # again, and without `order:` the same page can repeat or skip rows
    # under writes. Both are why `offset:` requires `limit:` and
    # `order:` while `limit:` alone is a valid "at most N" read. A full
    # walk belongs to `find_each`.
    #
    # @param conditions [Hash{Symbol => Object}, nil] the `find_by`
    #   conditions contract, unchanged (a nil VALUE inside a condition
    #   means `IS NULL`, an operator hash carries comparisons and the
    #   null test (`{ is_not: nil }` → `IS NOT NULL`), an Array means
    #   `IN (...)` membership, anything else escaped equality — keys
    #   are code, not input, and an unknown column surfaces as a loud
    #   SQL error from the driver). nil CONDITIONS (the argument
    #   itself) mean the whole table: no WHERE clause at all.
    # @param order [Symbol, nil] `:desc` or `:asc` — the `id` sort
    #   direction of the returned rows; nil leaves the order
    #   implementation-defined
    # @param limit [Integer, nil] the maximum number of rows to return;
    #   nil means no limit. Must be positive.
    # @param offset [Integer, nil] how many matching rows to skip before
    #   collecting the window; nil means zero. Requires both `limit:`
    #   and `order:`.
    # @return [Array] one record per matching row in the window, mapped
    #   by the receiver's `from_row` — an empty array on no match (never
    #   nil); which row comes first without `order:` is
    #   implementation-defined, so a caller that needs order passes it
    # @raise [ArgumentError] an empty conditions hash — the whole
    #   table is spelled nil, so an empty hash means the condition
    #   builder broke; an `order:` other than `:asc`/`:desc` (a
    #   typo must fail loud, not silently return unordered rows); a
    #   `limit:` that is not a positive Integer; an `offset:` that is
    #   not a non-negative Integer, or that arrives without `limit:` or
    #   `order:`; or the `where_clause` value contract — an empty Array
    #   value or an Array carrying nil
    # @raise [NotImplementedError] the model has not declared
    #   `table_name` / `only_columns` (the declaration stubs raise)
    # @example typed association reader — declaration and walk agree
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
      sql += " WHERE " + where_clause(conditions) unless conditions.nil?
      sql += ' ORDER BY "id" ' + (order == :asc ? "ASC" : "DESC") unless order.nil?
      unless limit.nil?
        sql += " LIMIT " + Sqlx.quote(limit)
        sql += " OFFSET " + Sqlx.quote(offset) unless offset.nil?
      end
      find_by_sql(sql)
    end

    # the whole-table per-record walk. It uses the same keyset walk as
    # `find_in_batches`, but yields one record at a time: a caller with a
    # per-row side effect (send, enqueue, call) does not hold a batch of records
    # while it works. `find_in_batches` is the bulk counterpart that yields the
    # batch array.
    #
    # The conditions contract is the same as `fetch_many`, but rows
    # arrive in `id` order through keyset pagination — each batch asks
    # for the rows after the last id it saw, so a static table is
    # visited exactly once and no skipped-row arithmetic (OFFSET) is
    # involved. The block is required: without one there is no work to
    # do, and returning an enumerator would hide that.
    #
    # `batch_size` is the page size, not a total cap — a caller that
    # wants at most N rows uses `fetch_many(..., limit: N)`. The walk is
    # not a snapshot: rows inserted with a higher id during the walk may
    # be seen, and changing a row's id while it is being traversed is
    # outside the contract. A `break` in the block stops the walk.
    #
    # The `id` column is the cursor, read from the same projection the
    # record is built from; a model whose `only_columns` omits `id`
    # cannot use this entry (raise) rather than silently stopping after
    # the first batch. A table without an `id` column, a join, or a
    # descending full walk stays on raw `find_by_sql`.
    #
    # @param conditions [Hash{Symbol => Object}, nil] the `fetch_many`
    #   conditions contract, unchanged; nil means the whole table and
    #   an empty hash raises (a broken condition builder must not
    #   quietly widen into a full walk)
    # @param batch_size [Integer] how many rows one query reads; must be
    #   positive (the default is a page size, not a total cap)
    # @return [void]
    # @raise [ArgumentError] the block is missing; the conditions hash
    #   is empty; `batch_size` is not a positive Integer; or
    #   `only_columns` omits `id` (the cursor column)
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
      base_clause = conditions.nil? ? nil : where_clause(conditions)
      cursor = nil
      while true
        sql = "SELECT " + projection + " FROM " + quoted_table
        predicate = base_clause
        unless cursor.nil?
          cursor_predicate = '"id" > ' + Sqlx.quote(cursor)
          predicate = predicate.nil? ? cursor_predicate : predicate + " AND " + cursor_predicate
        end
        sql += " WHERE " + predicate unless predicate.nil?
        sql += ' ORDER BY "id" ASC LIMIT ' + Sqlx.quote(batch_size)
        rows = rows_by_sql(sql)
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

    # the whole-table per-batch walk: the bulk counterpart of `find_each`. It
    # uses the same keyset walk, but yields each batch's records as an Array, so
    # a caller that applies one bulk operation per batch (`update_all!`,
    # `upsert_all!`, a batch API) pays one block call and one write per batch
    # instead of one per record. It still hydrates the batch — there is no
    # Relation to hand a bulk statement to — so the memory bound is the batch
    # size, not the table.
    #
    # The conditions, `batch_size`, id cursor, snapshot, and `break`
    # contracts are the same as `find_each`. Empty batches are never
    # yielded; the final shorter batch is. `in_batches` is not provided:
    # that name promises a Relation, and this runtime has none; the
    # portable bulk form is this array plus `update_all!`·
    # `delete_all!`·`upsert_all!`.
    #
    # @param conditions [Hash{Symbol => Object}, nil] the `fetch_many`
    #   conditions contract, unchanged; nil means the whole table and
    #   an empty hash raises (a broken condition builder must not
    #   quietly widen into a full walk)
    # @param batch_size [Integer] how many rows one query reads; must be
    #   positive (the default is a page size, not a total cap)
    # @return [void]
    # @raise [ArgumentError] the block is missing; the conditions hash
    #   is empty; `batch_size` is not a positive Integer; or
    #   `only_columns` omits `id` (the cursor column)
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
      base_clause = conditions.nil? ? nil : where_clause(conditions)
      cursor = nil
      while true
        sql = "SELECT " + projection + " FROM " + quoted_table
        predicate = base_clause
        unless cursor.nil?
          cursor_predicate = '"id" > ' + Sqlx.quote(cursor)
          predicate = predicate.nil? ? cursor_predicate : predicate + " AND " + cursor_predicate
        end
        sql += " WHERE " + predicate unless predicate.nil?
        sql += ' ORDER BY "id" ASC LIMIT ' + Sqlx.quote(batch_size)
        rows = rows_by_sql(sql)
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

    # the lookup by the `id` column: the matching record, or `RecordNotFound` —
    # never nil, so a missing row becomes a 404 at the call site instead of a
    # nil that fails somewhere downstream. The column is `id` by decision, not
    # by declaration: every table this entry point serves has an `id` primary
    # key (a table without one does not use `find`), and a different key would
    # be its own declaration decision if a model ever needs it. Built on
    # `find_by`, so the conditions contract (escaping, loud unknown columns) and
    # the declaration pair come along — and the message names the table and the
    # id that missed, which is the diagnostic a 404 log needs.
    #
    # @param id [Integer, String] the `id` column value to match —
    #   treated as a condition value: it is escaped through
    #   `where_clause` like any other
    # @return [Object] the matching record — never nil
    # @raise [Sqlx::RecordNotFound] no row has that `id`
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

    # how many rows of the model's table match. One of the declared-query group:
    # the model owns the table, core owns the assembly, so every model answers
    # with the same `SELECT COUNT(*) FROM <quoted table>` instead of a
    # hand-rolled prepare/step/finalize cursor. With no conditions it is the
    # whole table; with a conditions hash it is the matching rows — the same
    # conditions contract `find_by`·`fetch_many`· `delete_all!` use (nil →
    # `IS NULL`, `{ is_not: nil }` → `IS NOT NULL`, an Array → `IN (...)`,
    # anything else → equality, keys unvalidated and unknown columns fail loud
    # from the driver).
    #
    # An empty table answers 0: a count is a number, so there is no
    # miss path to raise on. The projection declaration is not needed
    # here: COUNT(*) never reads columns.
    #
    # @param conditions [Hash{Symbol => Object}] the rows to count; an
    #   empty hash (or no argument) counts the whole table
    # @return [Integer] the number of matching rows — 0 when none
    #   match
    # @raise [NotImplementedError] the model has not declared
    #   `table_name` (the declaration stub raises)
    # @example
    #   ApiSetting.count
    #   # => 42
    #   ApiSetting.count({ verified: 1 })
    #   # => 7
    def count(conditions = {})
      sql = 'SELECT COUNT(*) AS total FROM "' + table_name + '"'
      sql += " WHERE " + where_clause(conditions) unless conditions.empty?
      rows = Sqlx::Database.exec_read(sql, [])
      rows.empty? ? 0 : rows[0]["total"].to_i
    end

    # whether a matching row exists, answered from `SELECT 1 ... LIMIT 1`
    # without hydrating a record. Four input forms, one per question: no
    # argument (or an empty hash) asks whether the table has any row at all — an
    # empty question here is well-defined, unlike `find_by({})`'s "which row?";
    # a conditions hash is the `find_by` conditions contract through the
    # inherited `where_clause`; a scalar is shorthand for an `id` lookup — the
    # same `id` column `find` uses, so an `exists?(user_id)` call site needs no
    # rewrite; `nil` and `false` answer false without running a query — there is
    # no row to look for.
    #
    # @param conditions [Hash{Symbol => Object}, Integer, String,
    #   nil] the conditions as above — a Hash is code-as-input on
    #   the `find_by` contract, a scalar matches the `id` column
    # @return [Boolean] true when one matching row exists
    # @raise [NotImplementedError] the model has not declared
    #   `table_name`
    # @example
    #   ApiSetting.exists?({ key: "flag" })  # conditions hash
    #   User.exists?(user_id)                # id shorthand
    #   Invoice.exists?                      # any row?
    def exists?(conditions = {})
      return false unless conditions
      conditions = { id: conditions } unless conditions.is_a?(Hash)
      sql = 'SELECT 1 FROM "' + table_name + '"'
      sql += " WHERE " + where_clause(conditions) unless conditions.empty?
      exists_by_sql(sql + " LIMIT 1")
    end

    # insert one row from a column/value hash and hand back the persisted
    # record. Core owns the mechanical middle (attrs keys become the INSERT
    # columns, the declared timestamp columns fill themselves, the row arrives
    # back through `find`) because it never varies by model; the id comes from
    # the INSERT's own `RETURNING` row, not a session-scoped last-insert value,
    # so a concurrent session cannot answer with its own id. Input preparation —
    # type conversion, association objects reduced to ids, dumps — stays in the
    # caller. This is a partial INSERT: exactly the columns the caller passed
    # plus the declared timestamps it left out, so a table without timestamp
    # columns needs no opt-out. Keys are code, not input, and are not validated:
    # an unknown column surfaces as a loud SQL error from the driver. There are
    # no model validations to run — a schema constraint is the validation this
    # layer has, and it reaches the caller as an exception: a UNIQUE violation
    # raises `Sqlx::RecordNotUnique`, other constraint failures surface as the
    # adapter's driver error.
    #
    # @param attrs [Hash{Symbol => Object}] column => value. Raw Ruby
    #   values bind through `write` (nil binds NULL). A declared
    #   `created_at`/`updated_at` the caller did not pass is filled
    #   with the current UTC time — one value shared by both columns,
    #   so an insert's two stamps agree; a timestamp the caller did
    #   pass wins over the stamp.
    # @return [Object] the persisted record, re-read by its `id` —
    #   never nil (the row was just written)
    # @raise [ArgumentError] on empty attrs — there is no row and no
    #   columns to insert
    # @raise [NotImplementedError] the model has not declared
    #   `table_name` / `only_columns` (the declaration stubs raise)
    # @raise [Sqlx::RecordNotUnique] a UNIQUE constraint
    #   rejects the insert
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
      stamps = []
      [ "created_at", "updated_at" ].each do |stamp|
        next unless declared.include?(stamp)
        next if given.include?(stamp)
        stamps << stamp
      end
      if !stamps.empty?
        now = Time.now.utc
        stamps.each do |stamp|
          columns << '"' + stamp + '"'
          placeholders << "?"
          values << now
        end
      end
      sql = 'INSERT INTO "' + table_name + '" (' + columns.join(", ") +
            ") VALUES (" + placeholders.join(", ") + ') RETURNING "id"'
      rows = write(sql, values)
      find(rows[0]["id"])
    end

    # rewrite a row's columns by an id hash write and hand back the re-read
    # record. The class-level shape is a decision: this runtime's models write
    # through class-level SQL (there is no instance `save`), so the entry reads
    # next to `create!` rather than as an instance method. The re-read is also
    # the loud half — an unknown id writes nothing (a 0-row UPDATE is silent)
    # and then `find` raises `RecordNotFound` instead of returning a record that
    # was never written. The declared `updated_at` fills itself when the caller
    # left it out; `created_at` is never touched. Same key rule as `create!`:
    # code, not input, an unknown column surfaces as a loud SQL error.
    #
    # @param id [Integer, String] the `id` of the row to rewrite —
    #   the same `id` column `find` looks up
    # @param attrs [Hash{Symbol => Object}] column => value, same
    #   binding contract as `create!`. A declared `updated_at` the
    #   caller did not pass is filled with the current UTC time; a
    #   value the caller did pass wins.
    # @return [Object] the re-read record — never nil on success
    # @raise [ArgumentError] on empty attrs — there is nothing to
    #   rewrite (stamp-only writes belong to a dedicated entry, not
    #   this one)
    # @raise [Sqlx::RecordNotFound] no row has that `id`
    # @raise [NotImplementedError] the model has not declared
    #   `table_name` / `only_columns` (the declaration stubs raise)
    # @example
    #   Post.update!(42, { title: "revised" })
    def update!(id, attrs)
      raise ArgumentError, "update!: attrs must not be empty" if attrs.empty?
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

    # rewrite every row matching a conditions hash and answer how many went: the
    # conditions-side counterpart of `update!` (which pins one row by id) and
    # the update-side counterpart of `delete_all!` (the same conditions
    # contract, the same count return). It exists so a batch fixup carries only
    # its conditions and values instead of hand-writing the same
    # `UPDATE <table> SET ... WHERE <clause>` — the assembly never varies by
    # model: the table comes from the declaration, the WHERE body from the
    # inherited `where_clause`, the SET half from the attrs keys.
    #
    # No timestamp is stamped: `update!` stamps because it hands back
    # a re-read record, and here the caller passes `updated_at` when
    # it wants it moved — a rewrite never moves a timestamp the
    # caller did not ask to move. nil conditions mean the whole
    # table: "every row" is an explicit nil the caller writes, never
    # an empty hash — an empty hash is the shape a broken condition
    # builder leaves behind, so it raises instead of quietly widening
    # the rewrite to every row (the same rule `delete_all!` keeps).
    #
    # @param conditions [Hash{Symbol => Object}, nil] the `find_by`
    #   conditions contract, unchanged (a nil VALUE inside a condition
    #   means `IS NULL`, an operator hash carries comparisons and the
    #   null test (`{ is_not: nil }` → `IS NOT NULL`), an Array means
    #   `IN (...)` membership, a Hash means a comparison like
    #   `{ lt: cutoff }`, anything else escaped equality — keys are
    #   code, not input, and an unknown column surfaces as a loud
    #   SQL error from the driver). nil CONDITIONS (the argument
    #   itself) mean the whole table: no WHERE clause at all.
    # @param attrs [Hash{Symbol => Object}] column => value, the
    #   `update!` binding contract for the SET half: keys are code
    #   (an unknown column is a loud SQL error), values bind through
    #   `?` (nil binds NULL, a Time binds in the runtime's stored
    #   form)
    # @return [Integer] the number of rows changed — 0 when no row
    #   matched
    # @raise [ArgumentError] on an empty conditions hash — the
    #   whole-table rewrite is spelled nil, so an empty hash means
    #   the condition builder broke — or on empty attrs (nothing to
    #   rewrite)
    # @raise [NotImplementedError] the model has not declared
    #   `table_name`
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
      sql += " WHERE " + where_clause(conditions) unless conditions.nil?
      Sqlx::Database.exec_write(sql, values)["count"]
    end

    # insert many rows in one statement, rewriting the row a conflict collides
    # with instead of failing: the bulk counterpart of `create!` for tables
    # whose identity is a unique index, not a primary key. It exists so an
    # import batch carries its rows and its uniqueness rule instead of
    # hand-writing the same `INSERT ... ON CONFLICT ... DO UPDATE` per row — the
    # assembly never varies by model.
    #
    # The conflict target is required, not defaulted: this runtime has
    # no schema reflection to read the table's unique indexes from,
    # and the table this entry exists for has no primary key to fall
    # back to — the caller names the columns that define the same
    # row. A conflict on any OTHER unique index is not this
    # statement's business and stays a loud constraint, so a typo in
    # the target cannot quietly swallow the wrong rows.
    #
    # The updated columns are the row keys minus `unique_by` — the
    # conflict columns are already the row being replaced. No
    # timestamp is stamped, as in `update_all!`: the caller passes
    # one when it wants one. A batch bigger than the driver's bound
    # value limit is the caller's to chunk — the entry builds one
    # statement per call.
    #
    # @param rows [Array[Hash{Symbol => Object}]] one hash per row to
    #   insert. Every row must have the same keys — a batch is one
    #   column list. Values bind through `?` (nil binds NULL, a Time
    #   binds in the runtime's stored form)
    # @param unique_by [Array[Symbol, String]] the columns of the
    #   unique index that defines the same row — code, not input;
    #   every column must be among the row keys (a conflict target
    #   outside the insert list would never fire)
    # @return [Integer] the number of rows inserted or rewritten
    # @raise [ArgumentError] on empty rows, an empty `unique_by`,
    #   rows with differing keys, a `unique_by` column outside the row
    #   keys, or no column left to update (every key part of
    #   `unique_by` — a skip-duplicates statement is not this entry)
    # @raise [Sqlx::RecordNotUnique] another unique index on the
    #   table rejects a row
    # @raise [NotImplementedError] the model has not declared
    #   `table_name`
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

    # remove the row with this `id`. The low-level delete half of the write
    # family: no callbacks exist on this runtime's models, so the delete/destroy
    # split collapses to one entry — and the bang is family consistency with
    # `create!`/`update!`, not a promise of raise-on-miss. An unknown id is
    # silent (0 rows): the caller's lookup already decided whether a missing
    # record is a 404 before reaching here, so a second existence check inside
    # the delete would be redundant. The column is `id` by the same decision
    # `find` pins it: every table this entry point serves has an `id` primary
    # key. Returns the deleted-row count — the number a row `delete` answers —
    # so a caller that needs "did anything go" reads it off the return instead
    # of a separate peek at the adapter's counter.
    #
    # @param id [Integer, String] the `id` column value to match
    # @return [Integer] the number of rows deleted — 0 when no row
    #   had that `id`
    # @raise [ArgumentError] the id is neither an Integer nor a
    #   String — an Array is the shape `delete_all!({ id: ids })`
    #   owns, and anything else would bind as text and miss
    #   silently on one adapter while the driver errors on the other
    # @raise [NotImplementedError] the model has not declared
    #   `table_name`
    # @example
    #   Post.delete!(42)
    #   # => 1
    def delete!(id)
      unless id.is_a?(Integer) || id.is_a?(String)
        raise ArgumentError, "delete!: id must be an Integer or String — pass many ids to delete_all!({ id: [...] })"
      end
      Sqlx::Database.exec_write('DELETE FROM "' + table_name + '" WHERE "id" = ?', [ id ])["count"]
    end

    # remove every row matching the conditions hash: the multi-row counterpart
    # of `delete!`, assembled from the model's `table_name` and the inherited
    # `where_clause`. It exists so an association cascade or a scope-shaped
    # cleanup carries only its conditions instead of hand-writing the same
    # `DELETE FROM <table> WHERE <clause>` — the assembly never varies by model.
    # nil conditions mean the whole table: "every row" is an explicit nil, never
    # an empty hash — an empty hash is the shape a broken condition builder
    # leaves behind, so it raises instead of quietly erasing every row (the same
    # rule `update_all!` keeps).
    #
    # @param conditions [Hash{Symbol => Object}, nil] the `find_by`
    #   conditions contract, unchanged (a nil VALUE inside a condition
    #   means `IS NULL`, an operator hash carries comparisons and the
    #   null test (`{ is_not: nil }` → `IS NOT NULL`), an Array means
    #   `IN (...)` membership, anything else escaped equality —
    #   keys are code, not input, and an unknown column surfaces as
    #   a loud SQL error from the driver). nil CONDITIONS (the
    #   argument itself) mean the whole table: no WHERE clause at all.
    # @return [Integer] the number of rows deleted — 0 when no row
    #   matched
    # @raise [ArgumentError] an empty conditions hash — the
    #   whole-table DELETE is spelled nil, so an empty hash means
    #   the condition builder broke; or the `where_clause` value
    #   contract — an empty Array value or an Array carrying nil
    # @raise [NotImplementedError] the model has not declared
    #   `table_name`
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
      sql += " WHERE " + where_clause(conditions) unless conditions.nil?
      Sqlx::Database.exec_write(sql, [])["count"]
    end

    # the single-row half of `find_by_sql`: walk the caller's SELECT and hand
    # back the row it yields first, hydrated from the same name-keyed shape, or
    # nil when it yields none. `find_by` assembles its `... LIMIT 1` statement
    # on this walk, so the single-row read shares one path with `find_by_sql`
    # instead of a second cursor. The statement is read fully, so a caller that
    # wants only the first row of a large set bounds it with `LIMIT`.
    #
    # A value enters by binding — the same list contract `rows_by_sql`
    # checks.
    #
    # Private on purpose: the supported single-row entries are `find_by`
    # (conditions, with `order:`) and `find_by_sql(...).first` (caller
    # SQL); this half is the assembly between them and may change
    # without notice.
    def one_by_sql(sql, values = nil)
      rows = rows_by_sql(sql, values)
      if rows.empty?
        nil
      else
        from_row(rows[0])
      end
    end

    # the existence half: walk the caller's SELECT and answer whether any row
    # arrived, without hydrating a record. `exists?` assembles its
    # `SELECT 1 ... LIMIT 1` statement on this walk, so the public entry owns
    # the model-side question and this half owns the walk. The values list is
    # checked against the statement's `?` placeholders the way `rows_by_sql`
    # checks it.
    #
    # Private on purpose: `exists?` is the supported existence entry and
    # `row_by_sql` the raw single-row read; this half is the assembly
    # between them and may change without notice.
    def exists_by_sql(sql, values = nil)
      bound = values_for_placeholders(sql, values)
      !Sqlx::Database.exec_read(sql, bound).empty?
    end

    # the predicates for one operator-hash condition value:
    # `column <op> <bound>` per whitelisted comparison (`lt`/`lte`/`gt`/`gte`),
    # each bound rendered through `Sqlx.quote` like every other value, plus the
    # null test (`is_not: nil` → `column IS NOT NULL`). The whitelist and the
    # bound checks are the entry validation: an unknown operator raises instead
    # of rendering a predicate nobody meant, an empty hash raises instead of
    # dropping the condition silently, a nil or structured comparison bound
    # raises because `quote` would render it into the comparison as text (`<
    # NULL` matches nothing; a nested Hash would stringify), and `is_not` with
    # any bound but nil raises because SQL's `IS NOT` is the null test here, not
    # a general negation.
    def operator_predicates(column, operators)
      raise ArgumentError, "where_clause: #{column} operator hash must not be empty" if operators.empty?
      predicates = []
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
        predicates << (column + " " + operator_sql + " " + Sqlx.quote(bound))
      end
      predicates
    end

    # one column's bound value: a declared json column serializes through
    # `Sqlx::Json` (nil is SQL NULL), any other column binds the value unchanged
    # so the adapter renders it by runtime type. This is why a caller hands a
    # write entry a logical Hash and never calls the codec itself. A declared
    # value JSON cannot represent raises here — the codec's contract, so a Time
    # never reaches the column as text. The declaration walk normalizes each
    # name the way `from_row` does, so a Symbol list stays correct rather than
    # silently skipping the column.
    def bound_value(column, value)
      names = json_columns.map { |name| name.to_s }
      if names.include?(column)
        Sqlx::Json.encode(value)
      else
        value
      end
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
    # are the public methods above — including the `find_by_sql` escape
    # hatch for joins and other caller-written SQL.
    private :one_by_sql, :exists_by_sql, :operator_predicates, :values_for_placeholders, :placeholder_count, :bound_value
  end
end
