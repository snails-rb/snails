# Hash — the key transforms and the query-string renderer.
#
# Each transform builds a NEW hash; the receiver is untouched.
class Hash
  # Percent-encoding table for one query-string component: space renders as
  # `+`, `A-Za-z0-9.-_~` pass through, and the rest percent-encodes.
  #
  # Table and pattern: `Hash#to_query` runs each value through `CGI.escape`,
  # which keeps only `A-Za-z0-9.-_~`, renders space as `+` (not `%20`), and
  # percent-encodes the rest.
  #
  # ASCII-only on purpose: a UTF-8 value would need a per-byte walk the
  # lookup-table substitution cannot express, so it passes through
  # unencoded — a caller feeding one must encode it before the call.
  QUERY_ESCAPES = {
    " " => "+",   "!" => "%21", "\"" => "%22", "#" => "%23",
    "$" => "%24", "%" => "%25", "&" => "%26", "'" => "%27",
    "(" => "%28", ")" => "%29", "*" => "%2A", "+" => "%2B",
    "," => "%2C", "/" => "%2F", ":" => "%3A", ";" => "%3B",
    "<" => "%3C", "=" => "%3D", ">" => "%3E", "?" => "%3F",
    "@" => "%40", "[" => "%5B", "\\" => "%5C", "]" => "%5D",
    "^" => "%5E", "`" => "%60", "{" => "%7B", "|" => "%7C",
    "}" => "%7D",
  }.freeze

  QUERY_ESCAPE_PATTERN = /[ !"\#$%&'()*+,\/:;<=>?@\[\\\]^`{|}]/.freeze

  def symbolize_keys
    out = {}
    each { |k, v| out[k.to_sym] = v }
    out
  end

  def stringify_keys
    out = {}
    each { |k, v| out[k.to_s] = v }
    out
  end

  # a new Hash with the block applied to every key at every depth; Arrays are
  # walked element-wise and non-collection values pass through. The receiver is
  # untouched.
  #
  # @return [Hash] a new Hash with the transformed keys
  # @example
  #   { "host_info" => { "os_name" => "ios" } }
  #     .deep_transform_keys { |key| key.to_s.camelize(:lower) }
  #   # => { "hostInfo" => { "osName" => "ios" } }
  def deep_transform_keys(&block)
    deep_transform(self, &block)
  end

  # the same transform. Typed hashes cannot widen in place in this runtime, so
  # the answer is a NEW Hash and the receiver keeps its old keys: callers must
  # use the return value (the bang name mirrors the non-bang method; the value
  # is the contract).
  #
  # @return [Hash] a new Hash with the transformed keys
  # @example
  #   { "host_info" => 1 }.deep_transform_keys! { |key| key.to_s.camelize(:lower) }
  #   # => { "hostInfo" => 1 }
  def deep_transform_keys!(&block)
    deep_transform_keys(&block)
  end

  # the query string rendered for `key: value` options: a scalar becomes
  # `key=value`, a nil value renders its key alone, a nested Hash becomes
  # `outer[inner]`, and a scalar Array repeats `key[]`. Pairs sort at each
  # level.
  #
  # Not modeled, and raises when reached: an Array carrying a Hash or an
  # Array element, and a top-level Array (`Array#to_query`). A non-ASCII
  # value passes through unencoded — see `QUERY_ESCAPES`.
  #
  # @param namespace [String, nil] the enclosing key for a nested Hash
  # @return [String] the `&`-joined query string
  # @raise [ArgumentError] an Array element is a Hash or an Array
  # @example
  #   { name: "David", page: 2 }.to_query  # => "name=David&page=2"
  #   { user: { name: "David" } }.to_query("user")
  #   # => "user%5Bname%5D=David"
  def to_query(namespace = nil)
    pairs = []
    each do |key, value|
      name = namespace.nil? ? "#{key}" : "#{namespace}[#{key}]"
      if value.is_a?(Hash)
        nested = value.to_query(name)
        pairs << nested unless nested.empty?
      elsif value.is_a?(Array)
        value.each do |item|
          if item.is_a?(Hash) || item.is_a?(Array)
            raise ArgumentError, "to_query: an Array element cannot be a Hash or an Array"
          end

          pairs << "#{escape_query_component(name + "[]")}=#{escape_query_component(item.to_s)}"
        end
      elsif value.nil?
        pairs << escape_query_component(name)
      else
        pairs << "#{escape_query_component(name)}=#{escape_query_component(value.to_s)}"
      end
    end
    # Array elements are order-bearing: sorting under a `key[]` namespace
    # would reorder the list.
    namespace.to_s.include?("[]") ? pairs.join("&") : pairs.sort.join("&")
  end

  def escape_query_component(text)
    text.gsub(QUERY_ESCAPE_PATTERN, QUERY_ESCAPES)
  end

  # One recursive step of `deep_transform_keys`.
  def deep_transform(object, &block)
    if object.is_a?(Hash)
      out = {}
      object.each { |key, value| out[yield(key)] = deep_transform(value, &block) }
      out
    elsif object.is_a?(Array)
      object.map { |element| deep_transform(element, &block) }
    else
      object
    end
  end

  private :escape_query_component, :deep_transform
end
