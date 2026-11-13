module Sqlx
  # The raw-SQL model base — the class apps subclass. The query layer
  # and the enum factory arrive by extend, the row-object layer by
  # include; the subclass contract stubs stay in the class body.
  class Base
    extend Query
    extend Model

    include Row

    # the table this model reads from: one of the two declarations the core
    # `find_by` assembles its SELECT from. A subclass declares it as a literal
    # one-liner (spinel has no metaprogramming for accessors); the base raises
    # so a model that forgot the declaration fails at the call instead of
    # splicing nil into the SQL.
    #
    # @return [String] the table name — code, not input, and not
    #   validated: an unknown table surfaces as a SQL error
    #   from the driver, the rule `where_clause` applies to its keys
    # @raise [NotImplementedError] on the base — the subclass has
    #   not declared it
    # @example
    #   def self.table_name = "widgets"
    def self.table_name
      raise NotImplementedError, "table_name: subclasses must declare"
    end

    # the columns this model reads: the projection half of the `find_by`
    # declaration pair, declared as a column-name array. It is a required
    # declaration, not an optional filter — core assembles it into the SELECT
    # list (every identifier quoted, so a reserved-word column like `order` is
    # safe), and hydration reads the projected names out of the row, so the
    # list's order binds no read. The base raises so a model that forgot the
    # declaration fails at the call instead of splicing nil into the SQL.
    #
    # @return [Array[Symbol, String]] the projected column names —
    #   code, not input, and not validated: an unknown column
    #   surfaces as a SQL error from the driver, the rule
    #   `where_clause` applies to its keys. An empty list assembles
    #   a malformed SELECT that the driver rejects with an error.
    # @raise [NotImplementedError] on the base — the subclass has
    #   not declared it
    # @example
    #   def self.only_columns = [:id, :email, :created_at]
    def self.only_columns
      raise NotImplementedError, "only_columns: subclasses must declare"
    end

    # The built-in timestamp columns: the default `datetime_columns` pair
    # and the names `create!`/`update!` stamp on write. A table without them
    # stays legal — hydration passes them by instead of raising.
    TIMESTAMP_COLUMNS = [ "created_at", "updated_at" ]

    # the projected columns whose stored TEXT is a time: the type exceptions the
    # default `from_row` below converts through the stored-time codec. Defaults
    # to the built-in timestamp pair; the option replaces the list wholesale, so
    # a model with extra time columns spells the pair plus its extras, and a
    # model that keeps time columns as raw storage text answers []. A declared
    # name outside `only_columns` is a declaration error (the timestamp pair
    # excepted — a table without them is legal).
    #
    # @return [Array[String]] the datetime column names — the
    #   timestamp pair by default
    # @example the default pair is replaced, so it is spelled out again
    #   def self.datetime_columns = %w[created_at updated_at deleted_at]
    def self.datetime_columns
      TIMESTAMP_COLUMNS
    end

    # the projected columns whose stored TEXT is a civil date: the type
    # exception the default `from_row` converts through `String#to_date`.
    # Defaults to none. A model with DATE columns declares them (the column
    # generator emits the list). The date codec is opt-in — the generated file
    # loads `runtime/ext/date` only for an app whose schema has a DATE column,
    # because requiring the date package costs build time and binary size even
    # when no value converts.
    #
    # @return [Array[String]] the date column names; [] when none
    # @example
    #   def self.date_columns = %w[happens_on issued_on]
    def self.date_columns
      []
    end

    # the projected columns whose stored 1/0 is a boolean: another type
    # exception of the default `from_row`.
    #
    # @return [Array[String]] the boolean column names; [] when none
    # @example
    #   def self.boolean_columns = %w[verified]
    def self.boolean_columns
      []
    end

    # the projected columns whose stored TEXT is JSON: a type exception that
    # travels both ways. The default `from_row` below decodes each declared
    # column through `Sqlx::Json`, and the write entries (`create!`, `update!`,
    # `update_all!`, `upsert_all!`) encode each declared value on the way in, so
    # a caller hands over the logical value (a Hash) and reads the logical value
    # back — the codec call never appears in app code. A value JSON cannot
    # represent raises at the write entry instead of being `to_s`-ed into the
    # column, the codec's own contract. Defaults to no json columns: an
    # undeclared column stores and reads exactly as raw text.
    #
    # @return [Array[String]] the json column names; [] when none
    # @raise [ArgumentError] the default `from_row` finds a declared
    #   name outside `only_columns`
    # @example
    #   def self.json_columns = %w[detail]
    def self.json_columns
      []
    end

    # the columns whose stored type is an integer: the condition-value cast
    # list. The model query layer parses a String condition value for a
    # declared column strictly as a decimal integer; a value that is not an
    # Integer or a decimal String raises `Sqlx::CastError` instead of reaching
    # the database as text. The list comes from `db/schema.sql` through
    # `gen/model_columns.rb`; a hand-written model declares it only when it
    # takes integer conditions. The empty default keeps exact string binding
    # for models without the declaration.
    #
    # @return [Array[String]] the integer column names; [] when none
    # @example
    #   def self.integer_columns = %w[id post_id price status]
    def self.integer_columns
      []
    end

    # the default hydration: one name-keyed row in, one record out. Every
    # projected column is copied by name and the declared type exceptions are
    # converted — `datetime_columns` through the stored-time codec,
    # `date_columns` through `String#to_date`, `boolean_columns` from the stored
    # 1/0, `json_columns` through `Sqlx::Json` (the same codec the write entries
    # encode with, so the column round-trips). A model whose row needs more than
    # the exceptions (value normalization) overrides this wholesale; the
    # declaration stubs still make a bare base call raise.
    #
    # @param row [Hash{String => Object}] one name-keyed row — the
    #   `rows_by_sql` shape: the projected column names as keys, the
    #   adapter's native values (Integer, Float, String, nil for NULL)
    # @return [Object] the hydrated record
    # @raise [NotImplementedError] the model declared no `only_columns`
    #   (the declaration stub raises before any copy runs)
    # @raise [ArgumentError] a declared exception names a column
    #   outside `only_columns` — only the built-in timestamp pair may
    #   be absent, so a typo raises instead of staying raw
    #   silently; or a declared date column arrived without the date
    #   codec loaded
    # @example declaration only — the model carries no method
    #   class Widget < Sqlx::Base
    #     COLUMNS = %w[id name created_at].each { |n| define_method(n) { read_attribute(n) } }
    #     def self.table_name = "widgets"
    #     def self.only_columns = COLUMNS.map { |c| c.to_sym }
    #   end
    def self.from_row(row)
      attrs = {}
      only_columns.each { |column| attrs[column] = row[column.to_s] }
      datetime_columns.each do |column|
        name = column.to_s
        if attrs.key?(name.to_sym)
          value = row[name]
          attrs[name.to_sym] = value.nil? ? nil : value.to_time
        elsif !TIMESTAMP_COLUMNS.include?(name)
          raise ArgumentError, "from_row: datetime column " + name + " is not in only_columns"
        end
      end
      date_columns.each do |column|
        name = column.to_s
        unless attrs.key?(name.to_sym)
          raise ArgumentError, "from_row: date column " + name + " is not in only_columns"
        end
        value = attrs[name.to_sym]
        if !value.nil? && !value.respond_to?(:to_date)
          raise ArgumentError, "from_row: date column " + name + " needs the date codec — require \"date\" and runtime/ext/date"
        end
        attrs[name.to_sym] = value.nil? ? nil : value.to_date
      end
      boolean_columns.each do |column|
        name = column.to_s
        unless attrs.key?(name.to_sym)
          raise ArgumentError, "from_row: boolean column " + name + " is not in only_columns"
        end
        attrs[name.to_sym] = row[name] == 1
      end
      json_columns.each do |column|
        name = column.to_s
        unless attrs.key?(name.to_sym)
          raise ArgumentError, "from_row: json column " + name + " is not in only_columns"
        end
        value = attrs[name.to_sym]
        # A scalar in a NUMERIC-affinity column (sqlite `JSON`) stores as
        # INTEGER/REAL: `to_s` recovers the text the codec wrote. String is
        # itself, nil is SQL NULL.
        attrs[name.to_sym] = value.nil? ? nil : Sqlx::Json.decode(value.to_s)
      end
      new(**attrs)
    end

    # every row of the model's table, in no implied order. Declared but not
    # implemented, by decision: core owns the signature and the contract, not
    # the SQL. Two call sites need it (a model's own `all` and one full-table
    # read), and a public API is easier to add than to remove, so each model
    # implements it over its own projection as in the example below.
    #
    # @return [Array] every row of the table — an empty array when
    #   the table has no rows (never nil); which row comes first
    #   is implementation-defined, so a caller that needs order
    #   writes its own SQL through `find_by_sql`
    # @raise [NotImplementedError] always, on the base (declaration only)
    # @example call
    #   Model.all
    # @example standard implementation form — the walk lives in
    #   the model so the element type matches the declared return type,
    #   and the projection is the model's own; a single-call body
    #   is one line when the line fits
    #   def self.all = find_by_sql("SELECT " + SELECT_COLUMNS + " FROM samples")
    def self.all
      raise NotImplementedError, "all: subclasses must override"
    end
  end
end
