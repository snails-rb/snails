module Sqlx
  # The row-object layer: the instance side of record building. The generic
  # constructor and the single column reader are included into Base, so models
  # inherit both; a hand-written `initialize` in a model overrides the
  # constructor.
  module Row
    # Builds a record from one row's column values. A model that reads its
    # columns through `read_attribute` needs no `initialize` of its own.
    #
    # Keys are checked against `only_columns` here, so a typo raises at the
    # constructor instead of reading as nil later. Missing keys are allowed:
    # an unselected column reads as nil.
    #
    # @param attrs [Hash{Symbol => Object}] the row's column values, keyed by
    #   column name
    # @raise [ArgumentError] a key is not one of the model's declared columns
    # @raise [NotImplementedError] the model declares no `only_columns` (an
    #   empty call never reaches the check)
    # @example record building — the class-side factory hands its columns over
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

    # Returns the stored value for a column. The model's accessor loop sends
    # every column read through this method, so the storage stays owned by
    # this layer. A key the row did not carry returns nil, the same as a NULL
    # value.
    #
    # @param name [Symbol, String] the column name (String is accepted — the
    #   accessor loop iterates member names as written)
    # @return [Object] the stored value, or nil when the key is absent
    # @example the accessor loop a model writes against this method
    #   %w[id email].each { |n| define_method(n) { read_attribute(n) } }
    def read_attribute(name)
      @attrs[name.to_sym]
    end
  end
end
