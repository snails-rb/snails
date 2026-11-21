module Sqlx

  # The validated declaration behind `Sqlx::Base.enum`: a plain value object
  # that holds the label => stored value mapping, validates it, and builds the
  # writer bound to one column. It generates no methods.
  class Enum
    # Validates the whole mapping at construction, so only a sound declaration
    # exists. Called by `Sqlx::Base.enum`; models do not call it directly.
    #
    # @param pairs [Hash{Symbol => Integer}] label => stored value, in
    #   declaration order — the same contract `Sqlx::Base.enum` documents
    # @raise [ArgumentError] an empty declaration, a non-Symbol key, a
    #   non-Integer value, or a duplicated value
    def initialize(pairs)
      raise ArgumentError, "enum: declaration is empty" if pairs.empty?
      @labels = []
      @values = []
      pairs.each do |key, value|
        unless key.is_a?(Symbol)
          raise ArgumentError, "enum: #{key.inspect} is not a Symbol label"
        end
        unless value.is_a?(Integer)
          raise ArgumentError, "enum: #{key} = #{value.inspect} is not an Integer"
        end
        if @values.include?(value)
          raise ArgumentError, "enum: value #{value} is declared twice"
        end
        @labels << key.to_s
        @values << value
      end
    end

    # Returns the label for a stored value. An unknown value returns nil: an
    # unrecognized raw value is a data question, not a declaration error, so it
    # does not raise.
    #
    # @param value [Integer] the stored value read from the column
    # @return [String, nil] the label, or nil when no entry claims the value
    # @example
    #   STATUS.label(@status_raw)
    #   # => "trialing" (nil for an unknown raw)
    def label(value)
      i = 0
      while i < @values.length
        return @labels[i] if @values[i] == value
        i += 1
      end
      nil
    end

    # Returns whether a stored value matches the label's value, for hand-written
    # enum predicates. The label lookup is strict: a label the declaration does
    # not carry raises, so a renamed or removed entry surfaces at the first
    # predicate call instead of the predicate returning false forever. An
    # unknown raw value returns false; `label` is the reader for data
    # questions.
    #
    # @param raw [Integer] the stored value read from the column
    # @param label [Symbol, String] the declaration label to compare — its
    #   stored-value spelling reads the same stored value, like `value`
    # @return [Boolean] true when the stored value equals the label's value,
    #   false for a different or unknown raw
    # @raise [ArgumentError] the label is not in the declaration
    # @example
    #   STATUS.label?(@status_raw, :trialing)
    #   # => true / false (raises for a label the declaration dropped)
    def label?(raw, label)
      value(label) == raw
    end

    # Returns the Integer an INSERT or UPDATE stores for a label. An unknown
    # name raises — the enum type's contract, not a `to_i` fallback that would
    # silently store 0. `EnumWriter#write!` converts through this method, so a
    # redeclared or renumbered enum cannot leave the writer using a stale
    # literal.
    #
    # @param text [Symbol, String] the label, or its stored-value spelling —
    #   both read the same stored value
    # @return [Integer] the stored value for the label
    # @raise [ArgumentError] the name is not in the declaration
    # @example
    #   STATUS.value(:trialing)
    #   # => 0
    def value(text)
      name = text.is_a?(Symbol) ? text.to_s : text
      i = 0
      while i < @labels.length
        return @values[i] if @labels[i] == name || @values[i].to_s == name
        i += 1
      end
      raise ArgumentError, "'#{text}' is not a valid enum value"
    end

    # Returns this declaration's writer for one column. The UPDATE is fixed:
    # `SET <column> = ?, updated_at = ? WHERE id = ?`.
    #
    # @param table [String] the table name — code, not input; not validated: an
    #   unknown table surfaces as a SQL error from the driver, the rule
    #   `where_clause` applies to its keys
    # @param column [String] the column name — the same code-not-input rule as
    #   `table`
    # @return [EnumWriter] a writer bound to the column, carrying this
    #   declaration for the label => stored-value conversion
    # @example
    #   def trialing! = STATUS.writer(table: "widgets", column: "status").write!(@id, :trialing)
    def writer(table:, column:)
      EnumWriter.new(table: table, column: column, declaration: self)
    end
  end

  # The writer `Enum#writer` returns: one column of one table, bound to its
  # declaration. It owns the UPDATE statement; the label conversion stays with
  # the declaration, so reads and writes share one mapping.
  class EnumWriter
    # Binds the writer to its column. Called by `Enum#writer`; models do not
    # call it directly.
    #
    # @param table [String] the table name — the `Enum#writer` contract
    # @param column [String] the column name — the `Enum#writer` contract
    # @param declaration [Enum] the declaration the writer converts through
    def initialize(table:, column:, declaration:)
      @table = table
      @column = column
      @declaration = declaration
    end

    # Stores the label's value on the bound column, sets `updated_at` to the
    # current UTC time, and matches the row by its primary key. An unknown
    # label raises before any SQL runs. An id no row matches is a silent no-op:
    # the bang promises the write attempt, not that the row existed. The table
    # must carry `updated_at`; one without it raises from the driver.
    #
    # Returns nil: a non-RETURNING UPDATE returns no row, and the bang promises
    # the attempt.
    #
    # @param id [Integer, String] the primary key of the row to update
    # @param label [Symbol, String] the label to store, or its stored-value
    #   spelling — both read the same declaration value
    # @return [nil]
    # @raise [ArgumentError] the label is not in the declaration
    # @example
    #   writer.write!(@id, :trialing)
    def write!(id, label)
      Sqlx::Base.write(
        "UPDATE " + @table + " SET " + @column + " = ?, updated_at = ? WHERE id = ?",
        [ @declaration.value(label), Time.now.utc, id ]
      )
      nil
    end
  end

end
