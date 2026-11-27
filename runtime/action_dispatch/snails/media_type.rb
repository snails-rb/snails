# The media type of a Content-Type value: the `type/subtype` before any
# parameters, lowercased. One parser serves the transport's decision to parse
# a body and the request's public predicate, so `request.json?` cannot say
# true for a body the dispatcher left unparsed.
module ActionDispatch
  module Http
    module MediaType
      # the media type from a Content-Type header value.
      #
      # @param value [String, nil] the raw header value
      # @return [String, nil] the lowercased type/subtype, nil when empty
      # @example
      #   ActionDispatch::Http::MediaType.parse("application/json; charset=utf-8")
      #   # => "application/json"
      def self.parse(value)
        return nil if value.nil?
        text = value.to_s
        return nil if text.length == 0
        cut = text.index(";")
        comma = text.index(",")
        if !comma.nil? && (cut.nil? || comma < cut)
          cut = comma
        end
        text = text[0, cut].to_s unless cut.nil?
        text = text.strip.downcase
        return nil if text.length == 0
        text
      end

      # whether the media type is JSON: `application/json` or a type with the
      # `+json` structured suffix (`application/vnd.api+json`). The transport
      # parses a body under the same rule.
      #
      # @param value [String, nil] the raw Content-Type header value
      # @return [Boolean] true when the body media type is JSON
      def self.json?(value)
        type = parse(value)
        return false if type.nil?
        type == "application/json" || type.end_with?("+json")
      end
    end
  end
end
