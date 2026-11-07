# The per-instance rule engine — read a value, apply the guards, report
# the rule's failure. It is the runtime half of validation, kept in its
# own file; `run_rule` stays private on the form so `valid?` is the only
# entry.
module Snails
  class Form
    # run_rule — guards first (the condition methods, then `allow_nil`/
    # `allow_blank`), then the rule itself. Values read through the
    # `read_attribute` seam — no dynamic dispatch on the value path. A
    # rule-level `message:` replaces the default message key (a declared
    # option nothing reads would be a silent failure). `elsif` keeps at
    # most one error per length violation, and the final `else` raises
    # so a rule registered without a matching branch can never pass
    # silently.
    def run_rule(attribute, rule, options)
      value = read_attribute(attribute)
      if options.is_a?(Hash)
        return if options.key?(:if) && !send(options[:if])
        return if options.key?(:unless) && send(options[:unless])
        return if options[:allow_nil] && value.nil?
        return if options[:allow_blank] && value.blank?
      end
      reported = options.is_a?(Hash) ? options[:message] : nil

      if rule == :presence
        @errors.add(attribute, reported || :blank) if value.blank?
      elsif rule == :length
        text_length = if value.is_a?(Array) || value.is_a?(Hash)
                        value.length
                      else
                        value.to_s.length
                      end
        exact = options[:is]
        if exact.is_a?(Integer)
          @errors.add(attribute, reported || :wrong_length, count: exact) if text_length != exact
        elsif options[:minimum].is_a?(Integer) && text_length < options[:minimum]
          @errors.add(attribute, reported || :too_short, count: options[:minimum])
        elsif options[:maximum].is_a?(Integer) && text_length > options[:maximum]
          @errors.add(attribute, reported || :too_long, count: options[:maximum])
        end
      elsif rule == :format
        if options[:without].is_a?(Regexp)
          @errors.add(attribute, reported || :invalid) if options[:without].match?(value.to_s)
        else
          @errors.add(attribute, reported || :invalid) unless options[:with].match?(value.to_s)
        end
      elsif rule == :inclusion
        unless member?(options[:in], value)
          @errors.add(attribute, reported || :inclusion, value: value)
        end
      elsif rule == :exclusion
        if member?(options[:in], value)
          @errors.add(attribute, reported || :exclusion, value: value)
        end
      elsif rule == :uniqueness
        column = options[:column] || attribute
        conditions = { column => value }
        scope = options[:scope]
        if scope.is_a?(Symbol)
          conditions[scope] = read_attribute(scope)
        elsif scope.is_a?(Array)
          scope.each do |name|
            conditions[name] = read_attribute(name)
          end
        end
        existing = options[:model].find_by(conditions)
        @errors.add(attribute, reported || :taken) unless existing.nil?
      elsif rule == :confirmation
        confirmed = read_attribute("#{attribute}_confirmation")
        if value.to_s != confirmed.to_s
          @errors.add("#{attribute}_confirmation".to_sym, reported || :confirmation, attribute: human_attribute_name(attribute))
        end
      else
        raise "unhandled validation rule: #{rule}"
      end
    end

    # member? — the inclusion/exclusion membership test: an Array value
    # asks every element (the collection field contract), any other value
    # is one membership test on the delimiter. Membership is the
    # delimiter's own `include?`, with no type coercion.
    def member?(members, value)
      if value.is_a?(Array)
        value.all? { |item| members.include?(item) }
      else
        members.include?(value)
      end
    end

    private :run_rule, :member?
  end
end
