module Sqlx

  # The validated declaration behind `Sqlx::Base.enum` — a plain value
  # object: no method generation (spinel has no metaprogramming for it), so
  # predicates stay literal model source and writers arrive as a bound
  # object. It owns the mapping's single source, the loud edges around it,
  # and the factory for its column-bound writer.
  class Enum
    # validates the whole mapping at construction so a sound declaration is the
    # only kind that exists. This body runs behind `Sqlx::Base.enum`, the entry
    # models use for their constants.
    #
    # @param pairs [Hash{Symbol => Integer}] label => storage value, in
    #   declaration order — the same contract the factory documents
    # @raise [ArgumentError] on an empty declaration, a non-Symbol key,
    #   a non-Integer value, or a duplicated value
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

    # the stored value → label reader, the read half of the declaration. Answers
    # nil for a value no label names: an unrecognized raw is a data-shape
    # question and does not raise.
    #
    # @param value [Integer] the slot read from the column
    # @return [String?] the label, or nil when no entry claims the
    #   value
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

    # the predicate half: answers whether a stored slot holds the given label's
    # value, for hand-written enum predicates. The label half is strict like
    # `value`: a name the declaration does not carry raises, so a renamed or
    # removed entry surfaces at the first predicate call instead of the
    # predicate answering false forever. An unknown raw answers false — `label`
    # stays the reader for data-shape questions.
    #
    # @param raw [Integer] the slot read from the column
    # @param label [Symbol, String] the declaration label to compare —
    #   a stored-value spelling reads the same slot, like `value`
    # @return [Boolean] true when the slot holds the label's value,
    #   false for a different or unknown raw
    # @raise [ArgumentError] the label is not in the declaration
    # @example
    #   STATUS.label?(@status_raw, :trialing)
    #   # => true / false (raises for a label the declaration dropped)
    def label?(raw, label)
      value(label) == raw
    end

    # the label → stored value write half: the Integer an INSERT or UPDATE
    # stores. An unknown name raises — the enum type's contract, not a `to_i`
    # fallback that would silently store 0 — and the standard bang writer reads
    # its slot through this, so a redeclared or renumbered enum cannot leave a
    # writer pinned to a stale literal.
    #
    # @param text [Symbol, String] the label, or its stored-value
    #   spelling — both read the same slot
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

    # this declaration's writer for one column: hands the mapping it already
    # owns to a bound writer, so the call site reads `STATUS.writer(...)` from
    # the same receiver the readers use instead of passing the declaration back
    # in. Core owns the UPDATE shape because it never varies by model (the same
    # `SET <column> = ?, updated_at = ? WHERE id = ?` every time) — the
    # hand-rolled per-model helper is where the SQL drifts and where each model
    # invents its own helper name.
    #
    # @param table [String] the table name — code, not input, and not
    #   validated: an unknown table surfaces as a loud SQL error from
    #   the driver, the rule `where_clause` applies to its keys
    # @param column [String] the column name — the same code-not-input
    #   rule as `table`
    # @return [EnumWriter] a writer bound to the column, carrying
    #   this declaration for the label -> stored-value conversion
    # @example
    #   def trialing! = STATUS.writer(table: "widgets", column: "status").write!(@id, :trialing)
    def writer(table:, column:)
      EnumWriter.new(table: table, column: column, declaration: self)
    end
  end

  # The bound writer behind `Enum#writer` — one column of one table. It owns
  # the UPDATE shape so the model carries no per-field write helper; the
  # label -> stored-value conversion stays with the bound declaration, so
  # the write's mapping is single-sourced the way reads are.
  class EnumWriter
    # binds the writer to its column. This body runs behind `Enum#writer`, the
    # entry members use for their bang writers.
    #
    # @param table [String] the `Enum#writer` contract, unchanged
    # @param column [String] the `Enum#writer` contract, unchanged
    # @param declaration [Enum] the `Enum#writer` contract, unchanged
    def initialize(table:, column:, declaration:)
      @table = table
      @column = column
      @declaration = declaration
    end

    # the single-column UPDATE: stores the label's value on the bound column,
    # stamps `updated_at` with the current UTC time, and matches the row by
    # primary key. An unknown label raises through the bound declaration's
    # strict `value` before any SQL runs, so a redeclared enum cannot leave a
    # writer pinned to a stale slot. A row the id does not match is a silent
    # no-op, the way the per-model helpers this replaces behaved — the bang
    # promises the write attempt, not that a row existed. The target table
    # carries `updated_at`; one without it fails loud from the driver. The write
    # entry answers the rows it returned; this writer answers nil — the bang
    # promises the attempt, and a non-RETURNING UPDATE returns no row.
    #
    # @param id [Integer] the primary key of the row to update
    # @param label [Symbol, String] the label to store, or its
    #   stored-value spelling — both read the same declaration slot
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
