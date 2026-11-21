module Sqlx
  # The model declaration surface: the enum factory a model calls in its class
  # body. The table and column declarations and the record-building factory
  # sit in Base's class body. Extended onto Base, so `enum` is a model class
  # method.
  module Model
    # Declares the model's enum mapping as one validated object in a constant:
    # label => stored value.
    #
    # The declaration generates no methods. Each member — reader, predicate,
    # bang writer — is written by hand in the model, as in the example below.
    #
    # @param pairs [Hash{Symbol => Integer}] label => stored value, in
    #   declaration order. Non-empty, Symbol keys, Integer values, and unique
    #   values: anything else raises at load, while the mistake is still cheap
    #   to find.
    # @return [Enum] the validated declaration
    # @raise [ArgumentError] an empty declaration, a non-Symbol key, a
    #   non-Integer value, or a duplicated value (two labels sharing one stored
    #   value would alias each other silently)
    # @example standard implementation form — each member is a hand-written
    #   one-liner (endless def); the predicate queries the declaration directly
    #   so an unknown label raises instead of the predicate answering false
    #   forever, and the writer assembles its UPDATE through the declaration's
    #   `writer`, so the model carries no per-field write helper
    #   class Widget < Sqlx::Base
    #     STATUS = enum(trialing: 0, active: 1, paused: 2)
    #
    #     def status = STATUS.label(@status_raw)
    #     def trialing? = STATUS.label?(@status_raw, :trialing)
    #     def trialing! = STATUS.writer(table: "widgets", column: "status").write!(@id, :trialing)
    #   end
    def enum(pairs)
      Enum.new(pairs)
    end

  end
end
