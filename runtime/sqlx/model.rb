module Sqlx
  # The declaration surface a model writes in its class body — the
  # table/column pair the query layer assembles from, the hydration
  # factory it walks with, and the enum factory. Extended onto Base
  # so each arrives as a model class method.
  module Model
    # the hand-written enum declaration for table-oriented models: one validated
    # object per enum, held in a model constant. It replaces the two parallel
    # constants a model would otherwise write by hand, whose pair can drift
    # silently. The name matches how app authors think of it, but it generates
    # no methods (spinel has no metaprogramming); the members are written out
    # by hand, as in the example below.
    #
    # @param pairs [Hash{Symbol => Integer}] label => storage value, in
    #   declaration order. Non-empty, Symbol keys, Integer values, and
    #   value-unique — anything else raises at load, while the mistake
    #   is still cheap to find.
    # @return [Enum] the validated declaration
    # @raise [ArgumentError] on an empty declaration, a non-Symbol key,
    #   a non-Integer value, or a duplicated value (two labels sharing
    #   one slot would alias each other silently)
    # @example standard implementation form — each member is a
    #   hand-written one-liner (endless def) because spinel has no
    #   metaprogramming to generate them; the predicate queries the
    #   declaration directly so an unknown label raises instead of the
    #   predicate answering false forever, and the writer assembles
    #   its UPDATE through the declaration's `writer` so the model
    #   carries no per-field write helper
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
