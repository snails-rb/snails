module ActionController
  # Narrowing accessors over the request-params tree.
  #
  # The request's params are a plain Hash here, so the counterpart of
  # `ActionController::Parameters` (`require`, `permit`) is a set of module
  # functions over that Hash — `require` cannot be a method on it: the call
  # would reach Kernel's private `require` instead.
  #
  # The narrowing is `is_a?` in narrowing position (the branch answers the
  # narrowed value), the shape the compiler already handles.
  module Params
    # the nested resource hash the params carry under `key` (`{"article" =>
    # {"title" => …}}`).
    #
    # @param params [Hash] the request's params
    # @param key [String] the resource key
    # @return [Hash] the nested hash; empty when the key is absent or holds
    #   something other than a hash
    # @example
    #   ActionController::Params.sub(params, "article")   # => { "title" => "…" }
    def self.sub(params, key)
      value = params.fetch(key, {})
      if value.is_a?(Hash)
        value
      else
        {}
      end
    end

    # the scalar under `key`, or `fallback` when the key is absent or holds a
    # nested hash or array.
    #
    # @param sub [Hash] the params, or a resource hash under one
    # @param key [String] the field key
    # @param fallback [String] what to answer when there is no scalar
    # @return [String] the scalar, or the fallback
    # @example
    #   ActionController::Params.str(params, "title", "")   # => "Hello"
    def self.str(sub, key, fallback)
      value = sub.fetch(key, fallback)
      if value.is_a?(String)
        value
      else
        fallback
      end
    end

    # the value the request carried for `key`, turning a missing or blank
    # parameter into a 400 instead of a nil that fails somewhere later. `sub` is
    # the forgiving counterpart (absent yields `{}`).
    #
    # @param params [Hash] the request's params
    # @param key [String] the required key
    # @return [Object] the value the request carried
    # @raise [ActionController::ParameterMissing] the key is absent, or its
    #   value is blank
    # @example
    #   ActionController::Params.require_key(params, "url")   # raises when absent
    def self.require_key(params, key)
      value = params.fetch(key, "")
      if value.is_a?(String) && value.empty?
        raise(ActionController::ParameterMissing.new(key))
      end
      unless params.key?(key)
        raise(ActionController::ParameterMissing.new(key))
      end
      value
    end

    # one key of a permitted set: the scalar the request carried for `key` is
    # added to `acc` under `name`, and left out otherwise, so a model write
    # leaves that attribute alone.
    #
    # @param acc [Hash] the accumulating permitted set
    # @param params [Hash] the request's params
    # @param key [String] the parameter key
    # @param name [Symbol] the attribute name the model reads the field under
    # @return [Hash] the accumulating set
    # @example
    #   ActionController::Params.permitted({}, params, "password", :password)
    def self.permitted(acc, params, key, name)
      if ActionController::Params.provided(params, key)
        acc[name] = ActionController::Params.str(params, key, "")
      end
      acc
    end

    # did the request carry a usable value for `key`? A blank string counts as
    # provided (`permit` keeps a blank, `compact` drops only an explicit nil);
    # an absent key, a JSON null, and a non-scalar do not.
    #
    # Named without a `?` on purpose — this is generated code, so
    # portability beats the Ruby idiom.
    #
    # @param sub [Hash] the params, or a resource hash under one
    # @param key [String] the key to test
    # @return [Boolean] true when a scalar was carried for the key
    # @example
    #   ActionController::Params.provided(params, "title")   # => true
    def self.provided(sub, key)
      return false unless sub.key?(key)
      value = sub.fetch(key, "")
      narrowed = if value.is_a?(String)
        value
      else
        nil
      end
      !narrowed.nil?
    end

    # the strong-parameters filter over the plain request-params Hash: only the
    # named keys survive, each value shaped by its filter.
    #
    # A Symbol names a scalar key and keeps its value when truthy; `{}`
    # keeps a nested Hash as-is (JSON leaves are already permitted); an
    # Array keeps only the listed keys of a Hash, or maps each Hash
    # element of an Array through the same list and passes non-Hash
    # elements through. Unknown top-level keys and unshaped values are
    # dropped.
    #
    # The result's top-level keys are Symbols (call sites read them that
    # way); nested keys keep the objects the request carried.
    #
    # @param source [Hash] the request params (String or Symbol keys)
    # @param filters [Array<Symbol, Hash>] the allowed keys and their shapes
    # @return [Hash{Symbol => untyped}] the permitted set
    # @raise [ArgumentError] source is not a Hash, filters is not an Array,
    #   or a filter has a shape other than a Symbol, `{}`, or an Array of
    #   Symbols
    # @example
    #   ActionController::Params.permit(
    #     { "uuid" => "u", "network_info" => [{ "name" => "en0", "extra" => 1 }] },
    #     [ :uuid, { network_info: [ :name ] } ]
    #   )
    #   # => { uuid: "u", network_info: [{ "name" => "en0" }] }
    def self.permit(source, filters)
      unless source.is_a?(Hash)
        raise ArgumentError, "permit expects the request params as a Hash, got #{source.class}"
      end

      unless filters.is_a?(Array)
        raise ArgumentError, "permit expects filters as an Array, got #{filters.class}"
      end

      result = {}
      filters.each do |filter|
        if filter.is_a?(Hash)
          filter.each do |name, spec|
            unless name.is_a?(Symbol)
              raise ArgumentError, "permit filter names must be Symbols, got #{name.inspect}"
            end

            unless spec == {} || spec.is_a?(Array)
              raise ArgumentError, "permit filter for #{name.inspect} must be {} or an Array, got #{spec.inspect}"
            end

            if spec.is_a?(Array)
              spec.each do |item|
                unless item.is_a?(Symbol)
                  raise ArgumentError, "permit list filters must be Symbols, got #{item.inspect}"
                end
              end
            end

            key = pick_key(source, name)
            next if key.nil?

            filtered = filter_value(source[key], spec)
            result[name] = filtered unless filtered.nil?
          end
        elsif filter.is_a?(Symbol)
          key = pick_key(source, filter)
          result[filter] = source[key] if !key.nil? && source[key]
        else
          raise ArgumentError, "permit filters must be Symbols or Hashes, got #{filter.inspect}"
        end
      end
      result
    end

    # The helpers below serve `permit` — an app never calls them.
    # Private on purpose: free to change or vanish without notice.
    #
    # `pick_key`: the key the params carry the name under, String before
    # Symbol; nil when neither is present.
    def self.pick_key(source, name)
      text = name.to_s
      return text if source.key?(text)
      return name if source.key?(name)
      nil
    end

    # `filter_value`: the value shaped by one filter spec — see `permit`.
    def self.filter_value(value, spec)
      if spec == {}
        return value if value.is_a?(Hash)
        nil
      elsif value.is_a?(Hash)
        names = []
        spec.each { |item| names << item.to_s }
        out = {}
        value.each do |key, nested|
          out[key] = nested if names.include?(key.to_s)
        end
        out
      elsif value.is_a?(Array)
        value.map { |element| element.is_a?(Hash) ? filter_value(element, spec) : element }
      end
    end

    private_class_method :pick_key, :filter_value
  end
end
