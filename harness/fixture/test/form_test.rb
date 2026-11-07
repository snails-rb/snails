require "set"
require_relative "test_helper"
require_relative "harness_runner"

# Snails::Form on the Sqlx-row shape: the literal FIELDS accessor loop
# (readers through read_attribute), input projection through the write
# seam, declaration-order errors, the private-engine boundary, and
# every declaration-time loud failure. This file runs on a graph with
# NO I18n, so messages come from core's built-in defaults through the
# interpolation fallback — the locale branch of `resolve_message`
# (I18n present, `default:`, "translation missing") is proven by the
# standalone API spike and, beyond that, by consumer app 422 contract
# tests that assert the exact locale strings through the real I18n.

# Stands in for a Sqlx model: the uniqueness rule only calls the
# standard query entry `find_by`, so no database is involved here.
class FormTakenUser
  def self.find_by(conditions)
    return { "id" => 1 } if conditions[:email] == "taken@example.test"
    return { "id" => 2 } if conditions[:email] == "not-an-email"
    return { "id" => 3 } if conditions[:email] == "scoped@example.test" && conditions[:kind] == "work"
    nil
  end
end

# The signup form mirrors the consumer app's flow: the app stores
# emails stripped + downcased, and the password short-circuit (blank ->
# too short -> too long -> confirmation) is expressed with allow_blank
# plus an `if:` guard instead of the original elsif chain. Fields are
# the row-style accessor loop — the same literal line a Sqlx model
# spells. The declarations use the call-level common options where one
# setting covers a whole call, and the rule hash where it is specific.
class FormSignupForm < Snails::Form
  FIELDS = %w[email password password_confirmation].each { |n| define_method(n) { read_attribute(n) } }
  message_scope "activerecord.errors.models.user.attributes"

  validates :email, presence: true
  validates :email,
    uniqueness: { model: FormTakenUser },
    format: { with: /\A[^@\s]+@[^@\s]+\z/ },
    allow_blank: true
  validates :password, presence: true
  validates :password, length: { minimum: 8, maximum: 128 }, allow_blank: true
  validates :password, confirmation: true, if: :password_length_ok?
  validate :email_is_blocked

  # The app stores the email stripped + downcased; rules read it that way.
  def normalize
    write_attribute(:email, email.to_s.strip.downcase)
  end

  def password_length_ok?
    text = password.to_s
    text.length >= 8 && text.length <= 128
  end

  def email_is_blocked
    errors.add(:email, "is blocked") if email == "blocked@example.test"
  end
end

# Uniqueness with a Symbol scope and no explicit column: the lookup uses
# the attribute name and carries a second field.
class FormScopedForm < Snails::Form
  FIELDS = %w[email kind].each { |n| define_method(n) { read_attribute(n) } }
  validates :email, uniqueness: { model: FormTakenUser, scope: :kind }
end

# The same scope as an Array keeps the other declaration shape.
class FormScopedArrayForm < Snails::Form
  FIELDS = %w[email kind].each { |n| define_method(n) { read_attribute(n) } }
  validates :email, uniqueness: { model: FormTakenUser, scope: [ :kind ] }
end

# Call-level common options: `if:` on presence, `allow_nil:`/`unless:`
# on length, `allow_blank:` on format, and `if:` on a custom validator.
class FormCallLevelForm < Snails::Form
  FIELDS = %w[name nickname email].each { |n| define_method(n) { read_attribute(n) } }
  validates :name, presence: true, if: :name_given?
  validates :nickname, length: { minimum: 3 }, allow_nil: true, unless: :nickname_exempt?
  validates :email, format: { with: /\A[^@\s]+@[^@\s]+\z/ }, allow_blank: true
  validate :cross_check, if: :check_cross?

  def name_given?
    !name.nil?
  end

  def nickname_exempt?
    nickname == "!!"
  end

  def check_cross?
    email == "cross@example.test"
  end

  def cross_check
    errors.add(:base, "cross check failed")
  end
end

# Canonical confirmation: declared on the primary field, compared with
# the conventional `_confirmation` field.
class FormConfirmationForm < Snails::Form
  FIELDS = %w[password password_confirmation].each { |n| define_method(n) { read_attribute(n) } }
  validates :password, confirmation: true
end

# Confirmation whose confirmation field is missing — the declaration
# refuses it (the test calls `validates` inside the case, so the class
# body loads).
class FormMissingConfirmationForm < Snails::Form
  FIELDS = %w[password].each { |n| define_method(n) { read_attribute(n) } }
end

# Length over a range (inclusive or exclusive); the Array case is the
# next form.
class FormLengthForm < Snails::Form
  FIELDS = %w[code].each { |n| define_method(n) { read_attribute(n) } }
  validates :code, length: { within: 3..5 }
end

class FormExclusiveLengthForm < Snails::Form
  FIELDS = %w[code].each { |n| define_method(n) { read_attribute(n) } }
  validates :code, length: { within: 3...5 }
end

class FormArrayLengthForm < Snails::Form
  FIELDS = %w[tags].each { |n| define_method(n) { read_attribute(n) } }
  validates :tags, length: { minimum: 3 }
end

# Format without: the value must not match the pattern.
class FormFormatWithoutForm < Snails::Form
  FIELDS = %w[slug].each { |n| define_method(n) { read_attribute(n) } }
  validates :slug, format: { without: /\s/ }
end

# One call, two fields, two rules: the error order is rule-major, as an
# HTTP list of errors reads when one rule fails on several fields.
class FormMultiAttributeForm < Snails::Form
  FIELDS = %w[a b].each { |n| define_method(n) { read_attribute(n) } }
  validates :a, :b, presence: true, length: { minimum: 5 }
end

# A custom validate method with a Symbol message key that nothing
# resolves (no locale entry, no I18n): the loud path.
class FormDefaultScopeForm < Snails::Form
  FIELDS = %w[name].each { |n| define_method(n) { read_attribute(n) } }
  validates :name, presence: true
  validate :name_key_missing

  def name_key_missing
    errors.add(:name, :nickname_taken) if name == "dup"
  end
end

# The guard options end to end: a rule-level `message:` override, a
# missing value skipped by allow_nil, and an `unless:` exemption.
class FormMessageForm < Snails::Form
  FIELDS = %w[title subtitle].each { |n| define_method(n) { read_attribute(n) } }
  validates :title, presence: { message: "must have a title" }
  validates :subtitle, length: { minimum: 3, allow_nil: true, unless: :subtitle_exempt? }

  def subtitle_exempt?
    subtitle == "!!"
  end
end

# A form that skipped the field loop — construction and validates must
# both refuse with the declaration line to copy.
class FormNoFields < Snails::Form
end

# Inclusion/exclusion delimiters: an Array enum list, a numeric Range,
# an Array-valued field, and a custom object that answers include?.
class FormKindList
  def include?(value)
    value == "counter" || value == "gauge"
  end
end

class FormInclusionForm < Snails::Form
  FIELDS = %w[kind].each { |n| define_method(n) { read_attribute(n) } }
  KINDS = %w[counter delta gauge].freeze

  validates :kind, presence: true
  validates :kind, inclusion: { in: KINDS }, allow_blank: true
end

class FormExclusionForm < Snails::Form
  FIELDS = %w[username].each { |n| define_method(n) { read_attribute(n) } }
  RESERVED = %w[admin root].freeze
  validates :username, exclusion: { in: RESERVED }
end

class FormRangeInclusionForm < Snails::Form
  FIELDS = %w[age].each { |n| define_method(n) { read_attribute(n) } }
  validates :age, inclusion: { in: 18..99 }
end

class FormArrayInclusionForm < Snails::Form
  FIELDS = %w[tags].each { |n| define_method(n) { read_attribute(n) } }
  validates :tags, inclusion: { in: %w[red green blue] }
end

class FormCustomInclusionForm < Snails::Form
  FIELDS = %w[kind].each { |n| define_method(n) { read_attribute(n) } }
  validates :kind, inclusion: { in: FormKindList.new }
end

class FormSetInclusionForm < Snails::Form
  FIELDS = %w[kind].each { |n| define_method(n) { read_attribute(n) } }
  KINDS = Set.new([ "counter", "gauge" ]).freeze
  validates :kind, inclusion: { in: KINDS }
end

class FormInclusionMessageForm < Snails::Form
  FIELDS = %w[kind].each { |n| define_method(n) { read_attribute(n) } }
  validates :kind, inclusion: { in: %w[a b], message: "must be a or b" }
end

class FormInclusionOrderForm < Snails::Form
  FIELDS = %w[a b].each { |n| define_method(n) { read_attribute(n) } }
  validates :a, inclusion: { in: %w[x] }
  validates :b, exclusion: { in: %w[y] }
end

class FormTest < TestBase
  def assert_equal(expected, actual, msg = nil)
    raise(msg || "expected #{expected.inspect}, got #{actual.inspect}") unless expected == actual
  end

  def assert_argument_error(fragment)
    raised = nil
    begin
      yield
    rescue ArgumentError => e
      raised = e
    end
    raise "expected ArgumentError containing #{fragment}" if raised.nil?
    raise "wrong message: #{raised.message}" unless raised.message.include?(fragment)
  end

  # Input projection: String and Symbol keys both land on the fields,
  # a key outside FIELDS never enters the form (unknown HTTP keys, and
  # framework state like `errors`), the accessor loop answers through
  # read_attribute, and anything that is not a Hash is a caller bug —
  # loud.
  def test_projects_declared_fields
    form = FormSignupForm.new({ "email" => "a@b.test", :password => "password", "device_uuid" => "ignored", "errors" => "clobber" })
    assert_equal [ "email", "password", "password_confirmation" ], FormSignupForm.field_names
    names = FormSignupForm.field_names
    names << "ghost"
    assert_equal [ "email", "password", "password_confirmation" ], FormSignupForm.field_names
    assert_equal "a@b.test", form.email
    assert_equal "password", form.password
    assert_equal nil, form.password_confirmation
    assert_equal nil, form.read_attribute(:device_uuid)
    begin
      form.write_attribute(:device_uuid, "x")
      raise "expected ArgumentError for an undeclared write"
    rescue ArgumentError => e
      assert_equal true, e.message.include?("is not a field")
    end
    assert_equal true, form.errors.is_a?(Snails::Form::Errors)
    assert_equal 0, form.errors.size
    begin
      FormSignupForm.send(:new, "a@b.test")
      raise "expected ArgumentError for a non-Hash input"
    rescue ArgumentError => e
      assert_equal true, e.message.include?("must be a Hash")
    end
  end

  # A form without the FIELDS loop is refused at construction with the
  # declaration line to copy — not a bare NameError.
  def test_form_without_fields_is_refused
    assert_argument_error("must declare: FIELDS") do
      FormNoFields.new({})
    end
  end

  # Blank input: both presence rules answer with core's default text in
  # declaration order — email before password — while length skips the
  # blank value (allow_blank) and confirmation stays behind its guard.
  def test_blank_errors_keep_declaration_order
    form = FormSignupForm.new({ "email" => " ", "password" => "" })
    assert_equal false, form.valid?
    assert_equal [ "Email can't be blank", "Password can't be blank" ], form.errors.full_messages
  end

  # A duplicate email answers the uniqueness message alone.
  def test_taken_error_matches_contract
    form = FormSignupForm.new({ "email" => "taken@example.test", "password" => "password", "password_confirmation" => "password" })
    assert_equal false, form.valid?
    assert_equal [ "Email has already been taken" ], form.errors.full_messages
  end

  # Registration order is error order: uniqueness runs before format,
  # so an email that is both taken and malformed reports taken first.
  def test_taken_before_invalid_keeps_declaration_order
    form = FormSignupForm.new({ "email" => "not-an-email", "password" => "password", "password_confirmation" => "password" })
    assert_equal false, form.valid?
    assert_equal [ "Email has already been taken", "Email is invalid" ], form.errors.full_messages
  end

  # Length messages interpolate %{count} through core's own fallback,
  # one error per violation.
  def test_length_messages_interpolate_count
    short = FormSignupForm.new({ "email" => "a@b.test", "password" => "short", "password_confirmation" => "short" })
    assert_equal false, short.valid?
    assert_equal [ "Password is too short (minimum is 8 characters)" ], short.errors.full_messages

    long = FormSignupForm.new({ "email" => "a@b.test", "password" => "a" * 129, "password_confirmation" => "a" * 129 })
    assert_equal false, long.valid?
    assert_equal [ "Password is too long (maximum is 128 characters)" ], long.errors.full_messages
  end

  # Blank password: presence reports alone — length is allow_blank and
  # the confirmation guard fails, matching the original elsif chain.
  def test_blank_password_reports_only_blank
    form = FormSignupForm.new({ "email" => "a@b.test", "password" => "", "password_confirmation" => "anything" })
    assert_equal false, form.valid?
    assert_equal [ "Password can't be blank" ], form.errors.full_messages
  end

  # Short password: too_short reports alone — the `if:` guard keeps the
  # confirmation rule out of a length violation.
  def test_short_password_reports_only_too_short
    form = FormSignupForm.new({ "email" => "a@b.test", "password" => "short", "password_confirmation" => "different" })
    assert_equal false, form.valid?
    assert_equal [ "Password is too short (minimum is 8 characters)" ], form.errors.full_messages
  end

  # Mismatched confirmation on a valid-length password: exactly the
  # confirmation message, interpolated with the other field's name.
  def test_mismatch_reports_only_confirmation
    form = FormSignupForm.new({ "email" => "a@b.test", "password" => "password", "password_confirmation" => "different" })
    assert_equal false, form.valid?
    assert_equal [ "Password confirmation doesn't match Password" ], form.errors.full_messages
  end

  # The 422 detail shape: blocks in declaration order (email block,
  # then password block), newline-joined.
  def test_join_orders_messages_by_declaration
    form = FormSignupForm.new({ "email" => "taken@example.test", "password" => "password", "password_confirmation" => "different" })
    assert_equal false, form.valid?
    assert_equal "Email has already been taken\nPassword confirmation doesn't match Password", form.errors.join("\n")
  end

  # The normalize hook runs before validation: spaces and case fall
  # away, so the uniqueness lookup sees the stored form of the email.
  def test_normalize_runs_before_rules
    form = FormSignupForm.new({ "email" => "  TAKEN@Example.TEST ", "password" => "password", "password_confirmation" => "password" })
    assert_equal "taken@example.test", form.email
    assert_equal false, form.valid?
    assert_equal [ "Email has already been taken" ], form.errors.full_messages
  end

  # A custom validate method reports through errors.add with literal
  # text — no message key involved.
  def test_custom_validator_adds_string_message
    form = FormSignupForm.new({ "email" => "blocked@example.test", "password" => "password", "password_confirmation" => "password" })
    assert_equal false, form.valid?
    assert_equal [ "Email is blocked" ], form.errors.full_messages
  end

  # A uniqueness scope narrows the lookup: the same email is taken for
  # one kind and free for another; the Symbol and Array scope shapes
  # carry the same condition.
  def test_uniqueness_scope_narrows_lookup
    taken = FormScopedForm.new({ "email" => "scoped@example.test", "kind" => "work" })
    assert_equal false, taken.valid?
    assert_equal [ "Email has already been taken" ], taken.errors.full_messages

    free = FormScopedForm.new({ "email" => "scoped@example.test", "kind" => "home" })
    assert_equal true, free.valid?
    assert_equal true, free.errors.empty?

    array_taken = FormScopedArrayForm.new({ "email" => "scoped@example.test", "kind" => "work" })
    assert_equal false, array_taken.valid?
    assert_equal [ "Email has already been taken" ], array_taken.errors.full_messages
  end

  # valid? starts from an empty list: a failed run's errors are gone
  # after a clean run on the same instance (writes go through the seam).
  def test_valid_clears_previous_errors
    form = FormSignupForm.new({ "email" => "", "password" => "" })
    assert_equal false, form.valid?
    assert_equal true, form.errors.any?

    form.write_attribute(:email, "a@b.test")
    form.write_attribute(:password, "password")
    form.write_attribute(:password_confirmation, "password")
    assert_equal true, form.valid?
    assert_equal true, form.errors.empty?
    assert_equal 0, form.errors.size
  end

  # Declaration rejects a name that is not a declared field, a
  # non-Symbol attribute, and an unknown rule name at the call — and
  # registers nothing while doing it (a rejected validates is
  # all-or-nothing).
  def test_rejects_non_field_and_unknown_rule
    before = Snails::Form::VALIDATIONS.select { |entry| entry[0] == "FormScopedForm" }.size
    assert_equal 1, before

    assert_argument_error("is not a field") do
      FormScopedForm.validates(:emial, presence: true)
    end
    assert_argument_error("unknown validation rule :formt") do
      FormScopedForm.validates(:email, presence: true, formt: {})
    end
    assert_argument_error("expects Symbol attributes") do
      FormScopedForm.validates("email", presence: true)
    end

    after = Snails::Form::VALIDATIONS.select { |entry| entry[0] == "FormScopedForm" }.size
    assert_equal 1, after
  end

  # Declaration rejects option typos and missing required options:
  # every failure is loud at load, none silently skips a rule.
  def test_rejects_option_typos_and_missing_options
    assert_argument_error("has no option :minmum") do
      FormScopedForm.validates(:email, length: { minmum: 8 })
    end
    assert_argument_error("at least one of") do
      FormScopedForm.validates(:email, length: {})
    end
    assert_argument_error("only :presence and :confirmation accept") do
      FormScopedForm.validates(:email, format: true)
    end
    assert_argument_error("a Regexp") do
      FormScopedForm.validates(:email, format: { with: "[a-z]" })
    end
    assert_argument_error("not both") do
      FormScopedForm.validates(:email, format: { with: /a/, without: /b/ })
    end
    assert_argument_error("expects a Range") do
      FormScopedForm.validates(:email, length: { within: 3 })
    end
    assert_argument_error("expects a Symbol") do
      FormScopedForm.validates(:email, uniqueness: { model: FormTakenUser, column: "email" })
    end
    assert_argument_error("option :if expects a Symbol") do
      FormScopedForm.validates(:email, presence: { if: "always" })
    end
    assert_argument_error("validate has no option :message") do
      FormScopedForm.validate(:some_check, message: "x")
    end
    assert_argument_error("cannot skip nil or blank") do
      FormScopedForm.validates(:email, presence: { allow_blank: true })
    end
    assert_argument_error("String or Symbol") do
      FormScopedForm.validates(:email, presence: { message: 42 })
    end
    assert_argument_error("expects true or false") do
      FormScopedForm.validates(:email, length: { minimum: 3, allow_nil: "yes" })
    end
    assert_argument_error("is not a field") do
      FormScopedForm.validates(:password, presence: true)
    end
    assert_argument_error("expects a String") do
      FormScopedForm.message_scope(:english)
    end

    after = Snails::Form::VALIDATIONS.select { |entry| entry[0] == "FormScopedForm" }.size
    assert_equal 1, after
  end

  # errors.add contract: :base renders unprefixed, a declared field
  # prefixes with its human name (and answers on(attribute)), and an
  # unknown or non-Symbol attribute is refused.
  def test_errors_add_contract
    form = FormScopedForm.new({ "email" => "free@example.test", "kind" => "home" })
    assert_equal true, form.valid?
    form.errors.add(:base, "whole-input failure")
    form.errors.add(:email, "custom text")
    assert_equal [ "whole-input failure", "Email custom text" ], form.errors.full_messages
    assert_equal [ "custom text" ], form.errors.on(:email)

    begin
      form.errors.add(:nickname, "x")
      raise "expected ArgumentError for a name that is not a field"
    rescue ArgumentError => e
      assert_equal true, e.message.include?("is not a field")
    end
    # The Symbol/Hash slot types refuse a String literal at compile
    # where they can; these prove the run-time entry guards answer loud
    # too, for values crossing an untyped boundary.
    begin
      form.errors.add("email", "x")
      raise "expected ArgumentError for a non-Symbol attribute"
    rescue ArgumentError => e
      assert_equal true, e.message.include?("Symbol")
    end
    begin
      form.errors.on("email")
      raise "expected ArgumentError for a non-Symbol on"
    rescue ArgumentError => e
      assert_equal true, e.message.include?("Symbol")
    end
  end

  # The engine and declaration internals are private where they are
  # defined: the instance engine behind valid?, the message resolver
  # behind add, and the declaration checks on the form owner. The
  # public entry points are valid? / errors.add / validates.
  def test_private_helpers_not_reachable
    form = FormSignupForm.new({})
    begin
      form.run_rule(:email, :presence, true)
      raise "expected run_rule to be private"
    rescue NoMethodError
    end
    begin
      form.errors.resolve_message(:email, :blank, {})
      raise "expected resolve_message to be private"
    rescue NoMethodError
    end
    begin
      Snails::Form.check_rule_options(:presence, true)
      raise "expected check_rule_options to be private"
    rescue NoMethodError
    end
    begin
      Snails::Form.merge_rule_options(true, {})
      raise "expected merge_rule_options to be private"
    rescue NoMethodError
    end
  end

  # A Symbol message key nothing can resolve, with no I18n to ask:
  # a loud ArgumentError out of valid?, never an empty message.
  def test_unresolvable_custom_key_raises
    form = FormDefaultScopeForm.new({ "name" => "dup" })
    raised = nil
    begin
      form.valid?
    rescue ArgumentError => e
      raised = e
    end
    raise "expected ArgumentError from valid?" if raised.nil?
    assert_equal true, raised.message.include?("no built-in message for :nickname_taken")
  end

  # A form without message_scope resolves under its own default subtree
  # (the declared scope changes only which locale keys are asked).
  def test_default_scope_used_when_undeclared
    form = FormDefaultScopeForm.new({ "name" => "" })
    assert_equal false, form.valid?
    assert_equal [ "Name can't be blank" ], form.errors.full_messages
  end

  # A rule-level `message:` replaces the default text end to end —
  # declared, validated, and read by the engine (a declared option
  # nothing reads would be a silent failure).
  def test_rule_message_override
    form = FormMessageForm.new({ "title" => "" })
    assert_equal false, form.valid?
    assert_equal [ "Title must have a title" ], form.errors.full_messages
  end

  # allow_nil skips a missing value and unless: exempts the value the
  # method names — both keep a would-be length error off the list, and
  # an ordinary short value still reports.
  def test_allow_nil_and_unless_guard_rules
    missing = FormMessageForm.new({ "title" => "ok" })
    assert_equal true, missing.valid?

    exempt = FormMessageForm.new({ "title" => "ok", "subtitle" => "!!" })
    assert_equal true, exempt.valid?

    short = FormMessageForm.new({ "title" => "ok", "subtitle" => "ab" })
    assert_equal false, short.valid?
    assert_equal [ "Subtitle is too short (minimum is 3 characters)" ], short.errors.full_messages
  end

  # Input projection: when the input carries both "email" and :email,
  # the later spelling wins (hash order); the form never keeps two
  # copies of one field.
  def test_key_spelling_last_wins
    symbol_then_string = FormSignupForm.new({ :email => "symbol@example.test", "email" => "string@example.test" })
    assert_equal "string@example.test", symbol_then_string.email

    string_then_symbol = FormSignupForm.new({ "email" => "string@example.test", :email => "symbol@example.test" })
    assert_equal "symbol@example.test", string_then_symbol.email
  end

  # Canonical confirmation: declared on the primary field, compared with
  # the conventional `_confirmation` field. A missing confirmation is a
  # mismatch (the app's 422 contract) rather than a silent skip.
  def test_confirmation_uses_the_conventional_field
    mismatch = FormConfirmationForm.new({ "password" => "password", "password_confirmation" => "different" })
    assert_equal false, mismatch.valid?
    assert_equal [ "Password confirmation doesn't match Password" ], mismatch.errors.full_messages

    match = FormConfirmationForm.new({ "password" => "password", "password_confirmation" => "password" })
    assert_equal true, match.valid?

    missing = FormConfirmationForm.new({ "password" => "password" })
    assert_equal false, missing.valid?
    assert_equal [ "Password confirmation doesn't match Password" ], missing.errors.full_messages
  end

  # A confirmation rule needs its conventional field declared; the
  # declaration refuses before registering anything.
  def test_confirmation_field_must_be_declared
    before = Snails::Form::VALIDATIONS.select { |entry| entry[0] == "FormMissingConfirmationForm" }.size
    assert_equal 0, before

    assert_argument_error("needs the field :password_confirmation") do
      FormMissingConfirmationForm.validates(:password, confirmation: true)
    end

    after = Snails::Form::VALIDATIONS.select { |entry| entry[0] == "FormMissingConfirmationForm" }.size
    assert_equal 0, after
  end

  # Length over a range: `within:` turns into the same minimum/maximum
  # checks, including an exclusive end.
  def test_length_within_range
    short = FormLengthForm.new({ "code" => "ab" })
    assert_equal false, short.valid?
    assert_equal [ "Code is too short (minimum is 3 characters)" ], short.errors.full_messages

    exact = FormLengthForm.new({ "code" => "abcd" })
    assert_equal true, exact.valid?

    long = FormLengthForm.new({ "code" => "abcdef" })
    assert_equal false, long.valid?
    assert_equal [ "Code is too long (maximum is 5 characters)" ], long.errors.full_messages

    exclusive_ok = FormExclusiveLengthForm.new({ "code" => "abcd" })
    assert_equal true, exclusive_ok.valid?

    exclusive_long = FormExclusiveLengthForm.new({ "code" => "abcde" })
    assert_equal false, exclusive_long.valid?
    assert_equal [ "Code is too long (maximum is 4 characters)" ], exclusive_long.errors.full_messages
  end

  # Length counts an Array's elements, not the spelling of the array.
  def test_length_counts_array_elements
    short = FormArrayLengthForm.new({ "tags" => [ "a", "b" ] })
    assert_equal false, short.valid?
    assert_equal [ "Tags is too short (minimum is 3 characters)" ], short.errors.full_messages

    long_enough = FormArrayLengthForm.new({ "tags" => [ "a", "b", "c" ] })
    assert_equal true, long_enough.valid?
  end

  # Format without: a match is the failure, the inverse of `with:`.
  def test_format_without_matches_the_inverse
    spaced = FormFormatWithoutForm.new({ "slug" => "a b" })
    assert_equal false, spaced.valid?
    assert_equal [ "Slug is invalid" ], spaced.errors.full_messages

    plain = FormFormatWithoutForm.new({ "slug" => "ab" })
    assert_equal true, plain.valid?
  end

  # Inclusion reads its delimiter through include?: a member passes and a
  # non-member reports the built-in text. A blank value is skipped by
  # allow_blank, so the presence rule keeps the single blank error.
  def test_inclusion_membership_and_blank_guard
    member = FormInclusionForm.new({ "kind" => "gauge" })
    assert_equal true, member.valid?

    unknown = FormInclusionForm.new({ "kind" => "histogram" })
    assert_equal false, unknown.valid?
    assert_equal [ "Kind is not included in the list" ], unknown.errors.full_messages

    blank = FormInclusionForm.new({ "kind" => "" })
    assert_equal false, blank.valid?
    assert_equal [ "Kind can't be blank" ], blank.errors.full_messages
  end

  # Exclusion is the inverse: a reserved value reports and a free value
  # passes.
  def test_exclusion_membership
    reserved = FormExclusionForm.new({ "username" => "admin" })
    assert_equal false, reserved.valid?
    assert_equal [ "Username is reserved" ], reserved.errors.full_messages

    free = FormExclusionForm.new({ "username" => "alice" })
    assert_equal true, free.valid?
  end

  # A Range delimiter uses include?, so both bounds are inclusive.
  def test_inclusion_accepts_a_range
    inside = FormRangeInclusionForm.new({ "age" => 18 })
    assert_equal true, inside.valid?

    outside = FormRangeInclusionForm.new({ "age" => 17 })
    assert_equal false, outside.valid?
    assert_equal [ "Age is not included in the list" ], outside.errors.full_messages
  end

  # An Array value asks every element, so one bad tag fails the whole
  # field with one message.
  def test_inclusion_checks_every_array_element
    clean = FormArrayInclusionForm.new({ "tags" => [ "red", "blue" ] })
    assert_equal true, clean.valid?

    dirty = FormArrayInclusionForm.new({ "tags" => [ "red", "black" ] })
    assert_equal false, dirty.valid?
    assert_equal [ "Tags is not included in the list" ], dirty.errors.full_messages
  end

  # A custom object with include? is a valid delimiter: the rule delegates
  # membership instead of requiring an Array.
  def test_inclusion_accepts_a_custom_member_list
    member = FormCustomInclusionForm.new({ "kind" => "counter" })
    assert_equal true, member.valid?

    non_member = FormCustomInclusionForm.new({ "kind" => "delta" })
    assert_equal false, non_member.valid?
    assert_equal [ "Kind is not included in the list" ], non_member.errors.full_messages
  end

  # A Set is a valid include? delimiter: the runtime-appended rule registry
  # carries it and the engine answers the same membership as an Array.
  def test_inclusion_accepts_a_set
    member = FormSetInclusionForm.new({ "kind" => "counter" })
    assert_equal true, member.valid?

    non_member = FormSetInclusionForm.new({ "kind" => "delta" })
    assert_equal false, non_member.valid?
    assert_equal [ "Kind is not included in the list" ], non_member.errors.full_messages
  end

  # Rule order is error order: inclusion on :a precedes exclusion on :b.
  def test_inclusion_and_exclusion_keep_declaration_order
    form = FormInclusionOrderForm.new({ "a" => "z", "b" => "y" })
    assert_equal false, form.valid?
    assert_equal [ "A is not included in the list", "B is reserved" ], form.errors.full_messages
  end

  # A rule-level message replaces the default text end to end.
  def test_inclusion_message_override
    form = FormInclusionMessageForm.new({ "kind" => "c" })
    assert_equal false, form.valid?
    assert_equal [ "Kind must be a or b" ], form.errors.full_messages
  end

  # Declaration refuses each unusable delimiter: missing in:, a value
  # without include?, an empty list, and the unsupported within: alias.
  # A rejected call registers nothing.
  def test_inclusion_declaration_rejects_unusable_delimiters
    before = Snails::Form::VALIDATIONS.select { |entry| entry[0] == "FormInclusionForm" }.size
    assert_equal 2, before

    assert_argument_error("needs `in:`") do
      FormInclusionForm.validates(:kind, inclusion: {})
    end
    assert_argument_error("needs `in:`") do
      FormInclusionForm.validates(:kind, inclusion: { in: nil })
    end
    assert_argument_error("expects a collection responding to include?") do
      FormInclusionForm.validates(:kind, inclusion: { in: 3 })
    end
    assert_argument_error("expects a collection responding to include?") do
      FormInclusionForm.validates(:kind, inclusion: { in: :kinds })
    end
    assert_argument_error("is empty") do
      FormInclusionForm.validates(:kind, inclusion: { in: [] })
    end
    assert_argument_error("is empty") do
      FormInclusionForm.validates(:kind, inclusion: { in: Set.new })
    end
    assert_argument_error("has no option :within") do
      FormInclusionForm.validates(:kind, inclusion: { within: %w[counter] })
    end

    after = Snails::Form::VALIDATIONS.select { |entry| entry[0] == "FormInclusionForm" }.size
    assert_equal 2, after
  end

  # One call with two fields and two rules runs rule-major: both
  # presence errors, then both length errors.
  def test_multi_attribute_errors_follow_rule_order
    form = FormMultiAttributeForm.new({ "a" => "", "b" => "" })
    assert_equal false, form.valid?
    assert_equal [
      "A can't be blank",
      "B can't be blank",
      "A is too short (minimum is 5 characters)",
      "B is too short (minimum is 5 characters)",
    ], form.errors.full_messages
  end

  # Call-level common options apply to every rule in the call: `if:`
  # skips presence, `allow_nil:`/`unless:` skip length, `allow_blank:`
  # skips format, and `if:` guards the custom validator.
  def test_call_level_options_apply_to_every_rule
    clean = FormCallLevelForm.new({ "name" => "ok", "email" => "ok@example.test" })
    assert_equal true, clean.valid?

    skipped_name = FormCallLevelForm.new({ "email" => "ok@example.test" })
    assert_equal true, skipped_name.valid?

    blank_name = FormCallLevelForm.new({ "name" => "", "email" => "ok@example.test" })
    assert_equal false, blank_name.valid?
    assert_equal [ "Name can't be blank" ], blank_name.errors.full_messages

    exempt_nickname = FormCallLevelForm.new({ "name" => "ok", "nickname" => "!!", "email" => "ok@example.test" })
    assert_equal true, exempt_nickname.valid?

    short_nickname = FormCallLevelForm.new({ "name" => "ok", "nickname" => "ab", "email" => "ok@example.test" })
    assert_equal false, short_nickname.valid?
    assert_equal [ "Nickname is too short (minimum is 3 characters)" ], short_nickname.errors.full_messages

    blank_email = FormCallLevelForm.new({ "name" => "ok", "email" => "" })
    assert_equal true, blank_email.valid?

    bad_email = FormCallLevelForm.new({ "name" => "ok", "email" => "bad" })
    assert_equal false, bad_email.valid?
    assert_equal [ "Email is invalid" ], bad_email.errors.full_messages

    guarded_custom = FormCallLevelForm.new({ "name" => "ok", "email" => "cross@example.test" })
    assert_equal false, guarded_custom.valid?
    assert_equal [ "cross check failed" ], guarded_custom.errors.full_messages
  end
end

FixtureRunner.run(FormTest, [
  "test_projects_declared_fields",
  "test_form_without_fields_is_refused",
  "test_key_spelling_last_wins",
  "test_blank_errors_keep_declaration_order",
  "test_taken_error_matches_contract",
  "test_taken_before_invalid_keeps_declaration_order",
  "test_length_messages_interpolate_count",
  "test_blank_password_reports_only_blank",
  "test_short_password_reports_only_too_short",
  "test_mismatch_reports_only_confirmation",
  "test_confirmation_uses_the_conventional_field",
  "test_confirmation_field_must_be_declared",
  "test_join_orders_messages_by_declaration",
  "test_normalize_runs_before_rules",
  "test_custom_validator_adds_string_message",
  "test_uniqueness_scope_narrows_lookup",
  "test_length_within_range",
  "test_length_counts_array_elements",
  "test_format_without_matches_the_inverse",
  "test_inclusion_membership_and_blank_guard",
  "test_exclusion_membership",
  "test_inclusion_accepts_a_range",
  "test_inclusion_checks_every_array_element",
  "test_inclusion_accepts_a_custom_member_list",
  "test_inclusion_accepts_a_set",
  "test_inclusion_and_exclusion_keep_declaration_order",
  "test_inclusion_message_override",
  "test_inclusion_declaration_rejects_unusable_delimiters",
  "test_multi_attribute_errors_follow_rule_order",
  "test_call_level_options_apply_to_every_rule",
  "test_valid_clears_previous_errors",
  "test_rejects_non_field_and_unknown_rule",
  "test_rejects_option_typos_and_missing_options",
  "test_errors_add_contract",
  "test_private_helpers_not_reachable",
  "test_unresolvable_custom_key_raises",
  "test_default_scope_used_when_undeclared",
  "test_rule_message_override",
  "test_allow_nil_and_unless_guard_rules"
])
