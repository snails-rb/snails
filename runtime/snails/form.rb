# The form object — validation at the input boundary, without the ORM. It
# projects an input hash onto declared fields, runs declared rules in order, and
# answers an ordered message list. There is no persistence surface: no `save`,
# dirty tracking, callbacks, or associations, and a `Sqlx` row gains no `valid?`
# (a row is already stored; validation is for input that is not).
#
# Fields declare with the same literal accessor loop a Sqlx model uses for its
# columns, so `form.email` reads and the declaration carries no new vocabulary.
# Spinel unrolls a literal class-body loop, and `FIELDS` doubles as the registry
# for projection, `validates` checks, and `errors.add`. Values live behind
# `read_attribute` / `write_attribute` with no dynamic dispatch.
#
# Rules register in module-level arrays, not class ivars: spinel does not carry
# a class ivar into a subclass, so `valid?` selects entries by class name and a
# subclass does not inherit its parent's rules. Messages resolve through `I18n`
# at validation time and fall back to the default messages. Declaration checks
# live in `form/rule_options.rb`, the engine in `form/rule_engine.rb`.
module Snails
  class Form
    # ---- declaration registries (module-level, owner-partitioned) -----
    # Array constants, not class ivars: spinel does not carry a class ivar
    # into a subclass, and a class-body registration lands here with the
    # owner's class name.

    VALIDATIONS = []
    MESSAGE_SCOPES = []

    # A form declares its fields by assigning `FIELDS`; the base class holds
    # an empty array so the lookup in `field_names` has a constant to resolve.
    # A form that inherits this exact array has not declared its own fields.
    # The sentinel is private: a subclass's `FIELDS` is the public declaration.
    FIELDS = []
    private_constant :FIELDS

    # Options that may sit at the `validates` call level and apply to
    # every rule in that call — `validates :email, presence: true, if:
    # :ready?`. A rule-level option of the same name wins.
    DEFAULT_RULE_OPTIONS = [ :if, :unless, :allow_nil, :allow_blank ]

    # the field names this form declares, as written in its `FIELDS` accessor
    # loop (the projection filter and the `validates`/`errors.add` declaration
    # check's registry).
    #
    # @return [Array[String]] the names in declaration order — a copy,
    #   so a caller cannot mutate the `FIELDS` registry
    # @raise [ArgumentError] the form declares no `FIELDS` loop — a
    #   form without one cannot project input or check rule targets, so
    #   the guidance line replaces a bare NameError
    # @example
    #   FIELDS = %w[email password].each { |n| define_method(n) { read_attribute(n) } }
    def self.field_names
      fields = const_get("FIELDS")
      if fields.equal?(Form::FIELDS)
        raise ArgumentError, "#{self.name} must declare: FIELDS = %w[...].each { |n| define_method(n) { read_attribute(n) } }"
      end
      fields.dup
    end

    # register rules for declared fields. Rules run in registration order during
    # `valid?`, and the errors keep that order — an HTTP 422 body is an ordered
    # message list, so declaration order is the contract. One call may name
    # several fields; each rule's attributes are registered together, before the
    # next rule's (rule-major).
    #
    # Common options may sit at the call level and apply to every rule
    # in the call — `validates :email, presence: true, if: :ready?` —
    # or inside one rule's hash; a rule-level option wins.
    #
    # @param attributes [Array[Symbol]] field names from the form's `FIELDS` loop
    # @param rules [Hash[Symbol, (true, Hash)]] rule name => `true` or
    #   an option hash — the common options (`message`, `allow_nil`,
    #   `allow_blank`, `if`, `unless`) plus the rule's own (see
    #   `RULE_DECLARATION_OPTIONS`). `if`/`unless`/`allow_nil`/
    #   `allow_blank` at the call level apply to every rule below them.
    # @return [void]
    # @raise [ArgumentError] a non-Symbol attribute, a name that is not
    #   a declared field, an unknown rule, options that do not satisfy
    #   the rule, or a confirmation field that is not declared — a
    #   rejected call registers nothing
    # @example
    #   FIELDS = %w[email password password_confirmation kind].each { |n| define_method(n) { read_attribute(n) } }
    #
    #   validates :email, presence: true, format: { with: /\A...\z/ }, allow_blank: true
    #   validates :kind, inclusion: { in: %w[counter delta gauge] }, allow_blank: true
    #   validates :password, presence: true
    #   validates :password, length: { minimum: 8, maximum: 128 }, allow_blank: true
    #   validates :password, confirmation: true, if: :password_length_ok?
    def self.validates(*attributes, **rules)
      raise ArgumentError, "validates expects at least one attribute" if attributes.empty?
      raise ArgumentError, "validates expects at least one rule" if rules.empty?
      fields = field_names
      attributes.each do |attribute|
        raise ArgumentError, "validates expects Symbol attributes, got #{attribute}" unless attribute.is_a?(Symbol)
        unless fields.include?(attribute.to_s)
          raise ArgumentError, "validates: :#{attribute} is not a field of #{self.name} (fields: #{fields.join(", ")})"
        end
      end
      defaults = {}
      rule_entries = []
      rules.each do |rule, options|
        if DEFAULT_RULE_OPTIONS.include?(rule)
          defaults[rule] = options
        else
          rule_entries << [ rule, options ]
        end
      end
      raise ArgumentError, "validates expects at least one rule" if rule_entries.empty?
      checked = []
      rule_entries.each do |rule, options|
        merged = merge_rule_options(options, defaults)
        checked << [ rule, check_rule_options(rule, merged) ]
      end
      checked.each do |rule, _options|
        next unless rule == :confirmation
        attributes.each do |attribute|
          confirmation_field = "#{attribute}_confirmation"
          unless fields.include?(confirmation_field)
            raise ArgumentError, "validates: confirmation on :#{attribute} needs the field :#{confirmation_field} (fields: #{fields.join(", ")})"
          end
        end
      end
      checked.each do |rule, options|
        attributes.each do |attribute|
          VALIDATIONS << [ self.name, :rule, attribute, rule, options ]
        end
      end
    end

    # register an instance method as a custom validation. It runs in
    # registration order like a rule and reports through `errors.add`, for
    # conditions the declarative rules do not express (short-circuits,
    # cross-field rules). `if:`/ `unless:` guard the call with a Symbol method
    # name, as on a rule. The method is dispatched with `send`, so a typo'd name
    # raises NoMethodError at the first `valid?` instead of skipping silently.
    #
    # @param method_names [Array[Symbol]] the method names
    # @param options [Hash] the `if:`/`unless:` Symbol guards
    # @return [void]
    # @raise [ArgumentError] a non-Symbol name or an unknown option
    # @example
    #   validate :email_is_blocked, if: :check_email?
    #
    #   def email_is_blocked
    #     errors.add(:email, "is blocked") if email == "blocked@x.test"
    #   end
    def self.validate(*method_names, **options)
      raise ArgumentError, "validate expects at least one method" if method_names.empty?
      options.keys.each do |key|
        next if key == :if || key == :unless
        raise ArgumentError, "validate has no option :#{key} (allowed: if, unless)"
      end
      check_guard_options(options, "validate")
      guards = {}
      options.each do |key, value|
        guards[key] = value
      end
      method_names.each do |method_name|
        raise ArgumentError, "validate expects Symbols, got #{method_name}" unless method_name.is_a?(Symbol)
        VALIDATIONS << [ self.name, :custom, method_name, nil, guards ]
      end
    end

    # point this form's error keys at a locale subtree. Without it, keys resolve
    # under `activemodel.errors.models.<form_name>.attributes`.
    #
    # @param scope [String] the locale subtree prefix
    # @return [void]
    # @raise [ArgumentError] a non-String scope
    # @example
    #   message_scope "activerecord.errors.models.user.attributes"
    def self.message_scope(scope)
      raise ArgumentError, "message_scope expects a String, got #{scope.inspect}" unless scope.is_a?(String)
      MESSAGE_SCOPES << [ self.name, scope ]
    end

    # project the input hash onto the declared fields through the write seam,
    # then run the `normalize` hook. Keys are matched against `FIELDS` (String
    # and Symbol input keys both — HTTP params carry Strings; a later key wins
    # when both spellings are present, following hash order), so keys outside
    # the declaration are ignored: HTTP input is a superset by nature, and an
    # input key can never reach framework state (`errors`) because it is not a
    # field. A field the input never carried reads nil.
    #
    # @param values [Hash] the input hash
    # @return [Form]
    # @raise [ArgumentError] values is not a Hash (anything else is a
    #   caller bug, not empty input), or the form declares no `FIELDS`
    #   loop
    # @example
    #   form = SignupForm.new(params)
    def initialize(values = {})
      raise ArgumentError, "form input must be a Hash, got #{values.class}" unless values.is_a?(Hash)
      @errors = Errors.new(self)
      @values = {}
      fields = self.class.field_names
      values.each do |key, value|
        write_attribute(key, value) if fields.include?(key.to_s)
      end
      normalize
    end

    # the read seam of the field-storage path: every generated reader and the
    # rule engine route through this one method, so the value path holds no
    # dynamic dispatch. A missing field answers nil.
    #
    # @param name [Symbol, String] the field name (String accepted —
    #   the accessor loop iterates member names as written)
    # @return [untyped] the stored value, or nil when absent
    # @example the accessor loop a form writes against this seam
    #   FIELDS = %w[email password].each { |n| define_method(n) { read_attribute(n) } }
    def read_attribute(name)
      @values[name.to_sym]
    end

    # the write seam (there are no generated setters: spinel refuses an
    # interpolated `define_method` name, so writes stay a plain call). The
    # projection and the `normalize` hook write here. Input only — no dirty
    # tracking; a name outside `FIELDS` is a caller bug and fails loud instead
    # of storing a value no reader will see.
    #
    # @param name [Symbol, String] the field name
    # @param value [untyped] the value to store
    # @return [untyped] value
    def write_attribute(name, value)
      unless self.class.field_names.include?(name.to_s)
        raise ArgumentError, "form.write_attribute: :#{name} is not a field of #{self.class.name}"
      end
      @values[name.to_sym] = value
    end

    # reset the error list, run this class's registered validations in
    # registration order, and answer whether the input is clean. Rule guards
    # (`if`/`unless`/`allow_nil`/`allow_blank`) decide what each rule may
    # report, and custom `validate` methods run in the same order — so
    # `errors.full_messages` reflects declaration order, the ordered-list
    # contract a 422 body depends on. Calling it again starts from an empty
    # list.
    #
    # @return [bool]
    def valid?
      @errors = Errors.new(self)
      VALIDATIONS.each do |entry|
        next unless entry[0] == self.class.name
        if entry[1] == :custom
          guards = entry[4]
          if guards.is_a?(Hash)
            next if guards.key?(:if) && !send(guards[:if])
            next if guards.key?(:unless) && send(guards[:unless])
          end
          send(entry[2])
        else
          run_rule(entry[2], entry[3], entry[4])
        end
      end
      @errors.empty?
    end

    # the current error list: empty until a rule or custom method fails,
    # replaced by every `valid?` call.
    #
    # @return [Errors]
    def errors
      @errors
    end

    # the display name a full message prefixes (`email` -> `Email`,
    # `password_confirmation` -> `Password confirmation`). Override to carry
    # locale names.
    #
    # @param attribute [Symbol] the field name
    # @return [String]
    def human_attribute_name(attribute)
      attribute.to_s.humanize
    end

    # the input-normalization hook, called once from `new` before validation
    # reads any value. Override it for strips, downcasing, defaults — write
    # through `write_attribute` (there are no generated setters); input shaping
    # only, never persistence.
    #
    # @return [void]
    def normalize
    end
  end
end
