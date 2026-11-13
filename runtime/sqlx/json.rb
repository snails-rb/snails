# Codec for a schema-less json/jsonb column that stores serialized TEXT. `decode`
# reads back what `encode` wrote, so a value passing through is never reshaped.
# `encodable?` rejects values JSON cannot represent — Time, non-finite Float, or any
# object the json gem would stringify — because the gem's `strict: true` is accepted
# and ignored by the bundled native package.
module Sqlx
  module Json
    # whether JSON can represent this value on its own terms: nil, true/false, a
    # String, a finite number, or a nested Array/Hash of those (Hash keys may be
    # Symbols; they read back as Strings). This is the predicate `encode`
    # enforces, exposed so a caller holding untrusted input can check it before
    # storing the value — the same pairing as `label?` beside `label`.
    #
    # @param value [Object] the value headed for the column
    # @return [Boolean] true when `encode` accepts it; false for a Time,
    #   a non-finite Float, or any object the gem would stringify
    # @example
    #   Sqlx::Json.encodable?({ "a" => [ 1, true ] })  # => true
    #   Sqlx::Json.encodable?(Time.now)               # => false
    def self.encodable?(value)
      return true if value.nil? || value == true || value == false
      return true if value.is_a?(String) || value.is_a?(Integer)
      return value.finite? if value.is_a?(Float)
      if value.is_a?(Array)
        index = 0
        while index < value.length
          return false unless encodable?(value[index])
          index = index + 1
        end
        return true
      end
      if value.is_a?(Hash)
        valid = true
        value.each do |key, element|
          unless (key.is_a?(String) || key.is_a?(Symbol)) && encodable?(element)
            valid = false
          end
        end
        return valid
      end

      false
    end

    # the logical value a column holds: nil is SQL NULL and everything else is
    # JSON text, so `decode` reads it back equal. A value JSON cannot represent
    # raises instead of being `to_s`d into the column — a Time never arrives as
    # text by accident. JSON `null` is not distinguishable from SQL NULL here: a
    # caller that needs the literal writes it directly.
    #
    # @param value [Object] the logical value; nil for an absent column
    # @return [String?] the serialized text, or nil for SQL NULL
    # @raise [ArgumentError] the value is not a JSON value
    #   (`encodable?` answers false for it)
    # @example
    #   Sqlx::Json.encode({ a: 1 })  # => "{\"a\":1}"
    #   Sqlx::Json.encode(nil)       # => nil
    def self.encode(value)
      return nil if value.nil?
      unless encodable?(value)
        raise ArgumentError, "Sqlx::Json.encode: #{value.class} is not a JSON value"
      end

      JSON.generate(value)
    end

    # the logical value a column holds: nil is SQL NULL and a String is the
    # serialized text. Anything else is a caller bug — the logical value is
    # already in hand, so there is nothing to decode, and guessing would hide
    # it. Malformed text raises through the same door (see the file header for
    # why the parser's own class stays inside).
    #
    # @param text [Object] the stored column value; nil for SQL NULL
    # @return [Object] the decoded Hash/Array/scalar, or nil for SQL NULL
    # @raise [ArgumentError] the value is not a String, or is a String
    #   the parser cannot decode
    # @example
    #   Sqlx::Json.decode("{\"a\":1}")  # => { "a" => 1 }
    #   Sqlx::Json.decode(nil)          # => nil
    def self.decode(text)
      return nil if text.nil?
      unless text.is_a?(String)
        raise ArgumentError, "Sqlx::Json.decode: expected serialized text, got #{text.class}"
      end

      begin
        JSON.parse(text)
      rescue StandardError => error
        raise ArgumentError, "Sqlx::Json.decode: #{error.message}"
      end
    end
  end
end
