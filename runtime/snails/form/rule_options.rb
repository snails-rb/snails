# The declaration contract for `validates` — the rule-name allowlist,
# the option shapes, and each rule's required options. A separate file
# because it is the declaration surface's validator, not the runtime
# engine; the methods stay private on the form class so an app cannot
# reach past `validates`.
module Snails
  class Form
    # The options every rule accepts, and the options each rule brings
    # on top. The rule-name allowlist is the hash's keys: an unknown
    # rule or option key in `validates` is rejected at declaration
    # time, never ignored at validation time.
    COMMON_RULE_OPTIONS = [ :message, :allow_nil, :allow_blank, :if, :unless ]
    RULE_DECLARATION_OPTIONS = {
      presence: [],
      length: [ :minimum, :maximum, :is, :within, :in ],
      format: [ :with, :without ],
      inclusion: [ :in ],
      exclusion: [ :in ],
      uniqueness: [ :model, :column, :scope ],
      confirmation: [],
    }

    # merge_rule_options — one rule's options with the call-level
    # defaults. A rule-level key wins; `true` becomes the defaults hash
    # when there is one, and stays `true` otherwise. An invalid shape
    # is passed through so `check_rule_options` rejects it.
    def self.merge_rule_options(options, defaults)
      return options if defaults.empty?
      unless options == true || options.is_a?(Hash)
        return options
      end
      merged = {}
      defaults.each do |key, value|
        merged[key] = value
      end
      if options.is_a?(Hash)
        options.each do |key, value|
          merged[key] = value
        end
      end
      merged
    end

    # check_guard_options — the shared `if:`/`unless:` contract: a
    # Symbol method name, never a String or a Proc, so a typo is loud
    # at declaration and the call path stays dispatch-safe.
    def self.check_guard_options(options, label)
      [ :if, :unless ].each do |key|
        next unless options.key?(key)
        unless options[key].is_a?(Symbol)
          raise ArgumentError, "#{label} option :#{key} expects a Symbol method name"
        end
      end
    end

    # check_rule_options — the declaration contract for one rule entry:
    # the rule-name allowlist, `true` vs option-hash shape, common
    # option types, and each rule's required options. Everything a typo
    # could break is rejected here instead of surfacing as a silently
    # skipped rule later. `length` returns a normalized copy with
    # `within:`/`in:` turned into `minimum:`/`maximum:`.
    def self.check_rule_options(rule, options)
      unless RULE_DECLARATION_OPTIONS.include?(rule)
        known = RULE_DECLARATION_OPTIONS.keys.join(", ")
        raise ArgumentError, "unknown validation rule :#{rule} (known rules: #{known})"
      end
      if options == true
        unless rule == :presence || rule == :confirmation
          raise ArgumentError, "rule :#{rule} needs its option hash — only :presence and :confirmation accept bare `true`"
        end
        return options
      end
      unless options.is_a?(Hash)
        raise ArgumentError, "rule :#{rule} expects `true` or an option Hash, got #{options.inspect}"
      end

      allowed = COMMON_RULE_OPTIONS + RULE_DECLARATION_OPTIONS[rule]
      options.keys.each do |key|
        next if allowed.include?(key)
        raise ArgumentError, "rule :#{rule} has no option :#{key} (allowed: #{allowed.join(", ")})"
      end
      check_guard_options(options, "rule :#{rule}")
      if options.key?(:message)
        message = options[:message]
        unless message.is_a?(String) || message.is_a?(Symbol)
          raise ArgumentError, "rule :#{rule} option :message expects a String or Symbol"
        end
      end
      [ :allow_nil, :allow_blank ].each do |key|
        next unless options.key?(key)
        unless options[key] == true || options[key] == false
          raise ArgumentError, "rule :#{rule} option :#{key} expects true or false"
        end
      end
      if rule == :presence && (options.key?(:allow_nil) || options.key?(:allow_blank))
        raise ArgumentError, "presence cannot skip nil or blank values — it would never fail"
      end

      case rule
      when :presence, :confirmation
        nil
      when :length
        minimum = options[:minimum]
        maximum = options[:maximum]
        exact = options[:is]
        within = options[:in] || options[:within]
        unless within.nil?
          unless within.is_a?(Range)
            raise ArgumentError, "length `within:`/`in:` expects a Range, got #{within.inspect}"
          end
          if !minimum.nil? || !maximum.nil? || !exact.nil?
            raise ArgumentError, "length `within:`/`in:` cannot be combined with `minimum:`/`maximum:`/`is:`"
          end
          minimum = within.begin
          unless within.end.nil?
            maximum = within.exclude_end? ? within.end - 1 : within.end
          end
        end
        if minimum.nil? && maximum.nil? && exact.nil?
          raise ArgumentError, "length needs at least one of `minimum:`, `maximum:`, `is:`, `within:`"
        end
        if !exact.nil? && (!minimum.nil? || !maximum.nil?)
          raise ArgumentError, "length `is:` cannot be combined with `minimum:`/`maximum:`/`within:`"
        end
        [ [ :minimum, minimum ], [ :maximum, maximum ], [ :is, exact ] ].each do |key, bound|
          next if bound.nil?
          unless bound.is_a?(Integer)
            raise ArgumentError, "length #{key}: expects an Integer, got #{bound.inspect}"
          end
        end
        if !minimum.nil? && !maximum.nil? && minimum > maximum
          raise ArgumentError, "length `minimum:` #{minimum} exceeds `maximum:` #{maximum}"
        end
        normalized = {}
        options.each do |key, value|
          normalized[key] = value
        end
        normalized[:minimum] = minimum unless minimum.nil?
        normalized[:maximum] = maximum unless maximum.nil?
        return normalized
      when :format
        with = options[:with]
        without = options[:without]
        if with.nil? && without.nil?
          raise ArgumentError, "format needs `with:` or `without:` a Regexp"
        end
        if !with.nil? && !without.nil?
          raise ArgumentError, "format takes `with:` or `without:`, not both"
        end
        pattern = with.nil? ? without : with
        unless pattern.is_a?(Regexp)
          raise ArgumentError, "format needs `with:`/`without:` a Regexp, got #{pattern.inspect}"
        end
      when :inclusion, :exclusion
        delimiter = options[:in]
        if delimiter.nil?
          raise ArgumentError, "rule :#{rule} needs `in:` a collection responding to include?"
        end
        unless delimiter.respond_to?(:include?)
          raise ArgumentError, "rule :#{rule} `in:` expects a collection responding to include?, got #{delimiter.inspect}"
        end
        if delimiter.respond_to?(:empty?) && delimiter.empty?
          reason = rule == :inclusion ? "inclusion would reject every value" : "exclusion could never fail"
          raise ArgumentError, "rule :#{rule} `in:` is empty — #{reason}"
        end
      when :uniqueness
        model = options[:model]
        if model.nil? || !model.respond_to?(:find_by)
          raise ArgumentError, "uniqueness needs `model:` a class responding to find_by"
        end
        column = options[:column]
        unless column.nil? || column.is_a?(Symbol)
          raise ArgumentError, "uniqueness `column:` expects a Symbol, got #{column.inspect}"
        end
        scope = options[:scope]
        unless scope.nil?
          names = scope.is_a?(Array) ? scope : [ scope ]
          names.each do |name|
            unless name.is_a?(Symbol) && field_names.include?(name.to_s)
              raise ArgumentError, "uniqueness `scope:` #{name.inspect} is not a field of #{self.name}"
            end
          end
        end
      else
        raise "unhandled rule in declaration checks: #{rule}"
      end
      options
    end

    private_class_method :merge_rule_options, :check_guard_options, :check_rule_options
  end
end
