# frozen_string_literal: true

# The runtime encoder behind inline `render json: <expr>`: boot rewrites that to
# `render(ActionController::JsonRender.encode(v), content_type: "application/json")`.
#
# `as_json` runs first (a model's serialization hook), then a structural walk
# that reduces values to JSON primitives; the encoder writes its own JSON text
# rather than calling `JSON.generate`. Time renders through `to_fs(:iso8601)`
# — millisecond precision plus the zone offset, the JSON spelling this runtime
# fixes as its format contract.
#
# A value the compiler can type precisely is emitted as already-encoded text and
# never reaches this walk; a Hash literal, an untyped value, or an `as_json`
# outside those shapes is served here.
module ActionController
  module JsonRender
    # the JSON text behind `render json:`: `as_json` first, then a structural
    # walk and hand-written JSON text.
    #
    # @param value [untyped] the object to serialize
    # @return [String] JSON text
    # @example
    #   ActionController::JsonRender.encode({ "ok" => true })
    #   # => "{\"ok\":true}"
    def self.encode(value)
      emit_json(jsonify(value))
    end

    def self.jsonify(value)
      # A custom as_json wins, whatever the object. The guard is
      # arity-tolerant: `as_json` takes an options hash, and model-emitted
      # ones declare `(options = {})`.
      if !value.is_a?(Hash) && !value.is_a?(Array) && value.respond_to?(:as_json)
        return jsonify_structural(value.as_json)
      end
      jsonify_structural(value)
    end

    def self.jsonify_structural(value)
      case value
      when Hash
        out = {}
        value.each { |k, v| out[k.to_s] = jsonify(v) }
        out
      when Array
        value.map { |v| jsonify(v) }
      when Time
        value.to_fs(:iso8601)
      when String, Integer, Float, TrueClass, FalseClass, NilClass
        value
      when Symbol
        value.to_s
      else
        # Last resort: an object with no as_json — its to_s is more useful in
        # a payload than a crash.
        value.to_s
      end
    end

    # JSON text from an already-jsonified tree (String/Numeric/bool/
    # nil/Array/Hash-with-string-keys only).
    def self.emit_json(value)
      case value
      when Hash
        "{" + value.map { |k, v| "#{emit_json(k.to_s)}:#{emit_json(v)}" }.join(",") + "}"
      when Array
        "[" + value.map { |v| emit_json(v) }.join(",") + "]"
      when String
        quote_json(value)
      when NilClass
        "null"
      else # Integer, Float, true, false
        value.to_s
      end
    end

    JSON_ESCAPES = {
      "\"" => "\\\"", "\\" => "\\\\", "\b" => "\\b", "\f" => "\\f",
      "\n" => "\\n", "\r" => "\\r", "\t" => "\\t"
    }.freeze

    def self.quote_json(s)
      escaped = s.gsub(/["\\\x00-\x1f]/) do |c|
        JSON_ESCAPES[c] || format("\\u%04x", c.ord)
      end
      "\"#{escaped}\""
    end

    # Private on purpose: `encode` is the entry; these helpers are free to
    # change without notice.
    private_class_method :jsonify, :jsonify_structural, :emit_json, :quote_json
  end
end
