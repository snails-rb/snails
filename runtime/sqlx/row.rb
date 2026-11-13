module Sqlx
  # The row-object layer — the instance side of hydration: the generic
  # constructor and the read seam every literal accessor routes
  # through. Included into Base so models inherit the instance
  # methods; a hand-written model initialize still overrides.
  module Row
    # the generic row constructor behind the hash-backed accessor path: a model
    # whose readers come from its literal accessor loop needs no hand-written
    # initialize. Keys are checked against `only_columns` at this entry so a
    # typo'd keyword raises here instead of reading as a silent nil later;
    # missing keys are allowed — an unselected column reads as nil. A model that
    # hand-writes `initialize` simply overrides this.
    #
    # @param attrs [Hash{Symbol => Object}] the row's column values, keyed by column name
    # @raise [ArgumentError] when a key is not one of the model's declared columns
    # @raise [NotImplementedError] when the model declares no `only_columns` (an empty call never reaches the check)
    # @example hydration — the class-side factory hands its columns over
    #   def self.from_row(row)
    #     new(id: row["id"], name: row["name"])
    #   end
    def initialize(**attrs)
      unless attrs.empty?
        declared = self.class.only_columns
        attrs.each_key do |key|
          unless declared.include?(key)
            raise ArgumentError, "unknown attribute #{key} for #{self.class.table_name}"
          end
        end
      end
      @attrs = attrs
    end

    # the single read method behind the hash-backed accessors: the model's
    # accessor loop sends every column read through it, so the storage behind
    # the readers is core-owned and can change without touching models. A
    # missing key returns nil; an unselected column and a NULL value read the
    # same way.
    #
    # @param name [Symbol, String] the column name (String accepted —
    #   the accessor loop iterates member names as written)
    # @return [Object] the stored value, or nil when the key is absent
    # @example the accessor loop a model writes against this seam
    #   %w[id email].each { |n| define_method(n) { read_attribute(n) } }
    def read_attribute(name)
      @attrs[name.to_sym]
    end
  end
end
