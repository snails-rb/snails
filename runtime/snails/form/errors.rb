# The form's ordered error list — one entry per failure: the attribute,
# the raw message, and the display form an HTTP body ships. Message
# resolution and the English fallback live here because every read of an
# error goes through this object; the form owns declaration and
# validation, not display.
module Snails
  class Form
    class Errors
      # The messages core ships for the built-in rule keys, so an app
      # without `I18n` still answers real text and an app with one can
      # override per form through `message_scope`.
      DEFAULT_MESSAGES = {
        blank: "can't be blank",
        taken: "has already been taken",
        invalid: "is invalid",
        inclusion: "is not included in the list",
        exclusion: "is reserved",
        too_short: "is too short (minimum is %{count} characters)",
        too_long: "is too long (maximum is %{count} characters)",
        wrong_length: "is the wrong length (should be %{count} characters)",
        confirmation: "doesn't match %{attribute}",
      }

      # start the list on its owning form.
      #
      # @param form [Snails::Form] the owning form (message scope and
      #   attribute display names come from it)
      # @return [void]
      def initialize(form)
        @form = form
        @entries = []
      end

      # append one error. `message` is display text, or a Symbol key resolved
      # under the form's message scope; `**options` are interpolation values for
      # that message (`count:`, `attribute:`).
      #
      # @param attribute [Symbol] a declared field, or `:base` for an
      #   error that belongs to the whole input (no name prefix)
      # @param message [String, Symbol] display text or message key
      # @param options [Hash] interpolation values for the message
      # @return [void]
      # @raise [ArgumentError] a non-Symbol attribute, a name that is
      #   not a declared field, or a Symbol key nothing can resolve —
      #   an error that would render empty must raise here
      # @example
      #   errors.add(:email, :taken)
      #   errors.add(:password, :too_short, count: 8)
      #   errors.add(:base, "something went wrong")
      def add(attribute, message, **options)
        unless attribute.is_a?(Symbol)
          raise ArgumentError, "errors.add expects a Symbol attribute, got #{attribute.inspect}"
        end
        unless attribute == :base || @form.class.field_names.include?(attribute.to_s)
          raise ArgumentError, "errors.add: :#{attribute} is not a field of #{@form.class.name}"
        end
        text = resolve_message(attribute, message, options)
        full = attribute == :base ? text : "#{@form.human_attribute_name(attribute)} #{text}"
        @entries << [ attribute, text, full ]
      end

      # the display strings, in error order (the ordered list an HTTP 422 detail
      # ships).
      #
      # @return [Array[String]]
      def full_messages
        @entries.map { |entry| entry[2] }
      end

      # `full_messages.join`: the one call a response body needs
      # (`errors.join("\n")`).
      #
      # @param separator [String] the joiner
      # @return [String]
      def join(separator = ", ")
        full_messages.join(separator)
      end

      # no errors recorded.
      #
      # @return [bool]
      def empty?
        @entries.empty?
      end

      # at least one error recorded.
      #
      # @return [bool]
      def any?
        !@entries.empty?
      end

      # how many errors are recorded.
      #
      # @return [Integer]
      def size
        @entries.length
      end

      # the raw (unprefixed) messages recorded for one attribute. A non-Symbol
      # name is a caller bug: it would answer an empty list for a field that
      # does have messages, so the entry guard raises here as well.
      #
      # @param attribute [Symbol] the attribute
      # @return [Array[String]]
      # @raise [ArgumentError] a non-Symbol attribute
      def on(attribute)
        unless attribute.is_a?(Symbol)
          raise ArgumentError, "errors.on expects a Symbol attribute, got #{attribute.inspect}"
        end
        out = []
        @entries.each do |entry|
          out << entry[1] if entry[0] == attribute
        end
        out
      end

      # resolve_message — a String passes through; a Symbol becomes a
      # message key under the form's scope. With `I18n` present the app's
      # lookup and locale decide, `default:` carrying core's text; without
      # it core's text interpolates directly. A key with no built-in
      # default and no `I18n` raises, and an unresolvable key under `I18n`
      # answers that implementation's visible "translation missing" — never
      # an empty message.
      def resolve_message(attribute, message, options)
        return message if message.is_a?(String)
        unless message.is_a?(Symbol)
          raise ArgumentError, "errors.add expects a String message or Symbol message key, got #{message.inspect}"
        end
        key = "#{scope_key}.#{attribute}.#{message}"
        default = DEFAULT_MESSAGES[message]
        if defined?(I18n)
          if default.nil?
            I18n.t(key)
          else
            I18n.t(key, default: default, **options)
          end
        else
          if default.nil?
            raise ArgumentError, "no built-in message for :#{message} and no I18n to resolve #{key}"
          end
          interpolate(default, options)
        end
      end

      # scope_key — the declared `message_scope` for this form, else
      # the default subtree keyed by the form's class name.
      def scope_key
        scope = nil
        Form::MESSAGE_SCOPES.each do |entry|
          scope = entry[1] if entry[0] == @form.class.name
        end
        return scope unless scope.nil?
        "activemodel.errors.models.#{form_name}.attributes"
      end

      # form_name — the form's class name without namespace nesting,
      # underscored for a locale key ("Api::SignupForm" -> "signup_form").
      def form_name
        parts = @form.class.name.split("::")
        parts[parts.length - 1].to_s.underscore
      end

      # interpolate — the no-I18n text path: substitute each option's
      # `%{name}` token.
      def interpolate(text, options)
        out = text
        options.each do |name, value|
          out = out.gsub("%{#{name}}", value.to_s)
        end
        out
      end

      private :resolve_message, :scope_key, :form_name, :interpolate
    end
  end
end
