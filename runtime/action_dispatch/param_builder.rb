# Request-parameter builder: a query string or an urlencoded body into the
# nested params a controller reads.
#
# A port of actionpack's `QueryParser.each_pair` (split and decode) and
# `ParamBuilder#store_nested_param` (nest). The nesting rules are the contract:
# arrays (`a[]`), hashes to any depth (`a[b][c]`), hashes in arrays (`a[][b]`),
# several resources in one request, and a key with no `=` as nil.
#
# The builder is exercised against 2,755 query strings (nil where a value
# would otherwise raise).
#
# Errors are a nil return, not a raise: a malformed %-escape, invalid UTF-8, a
# nesting deeper than 100, or a name used as both an Array and a Hash. The
# dispatcher answers 400.
module ActionDispatch
  module ParamBuilder
    DEPTH_LIMIT = 100

    # Raised inside a build and rescued by `build`; never escapes.
    class Invalid < StandardError
    end

    # the nested params for the pairs.
    #
    # @param keys [Array<String>] the decoded parameter names
    # @param values [Array<String>] the decoded values ("" where the pair
    #   carried none)
    # @param present [Array<Boolean>] which pairs carried a value
    # @return [Hash] the nested params; nil where the input is a 400
    # @example
    #   ActionDispatch::ParamBuilder.build(["a[]"], ["1"], [true])   # => { "a" => ["1"] }
    def self.build(keys, values, present)
      params = {}
      i = 0
      while i < keys.length
        v = present[i] ? values[i] : nil
        store(params, keys[i], v, 0)
        i += 1
      end
      params
    rescue ParamBuilder::Invalid
      nil
    end

    # a query string (or an urlencoded body) straight to the nested params.
    #
    # @param s [String] the raw query string
    # @return [Hash] the nested params; nil where the input is a 400
    # @example
    #   ActionDispatch::ParamBuilder.from_query_string("a[b]=1")   # => { "a" => { "b" => "1" } }
    def self.from_query_string(s)
      keys = []
      values = []
      present = []
      return nil unless split(s, keys, values, present)
      ActionDispatch::ParamBuilder.build(keys, values, present)
    end

    # The helpers below serve `from_query_string` and `build` — an app never
    # calls them. Private on purpose: free to change or vanish without notice.
    #
    # `split`: split on `&` (and the spaces after it), `k=v` at the first `=`,
    # both halves www-form-decoded. A part with no `=` has a nil value, kept
    # apart in `present` so the arrays stay String-typed. Appends to the three
    # arrays; false when a %-escape is malformed.
    def self.split(s, keys, values, present)
      parts = s.split("&")
      i = 0
      while i < parts.length
        part = parts[i]
        if i > 0
          j = 0
          j += 1 while j < part.length && part[j] == " "
          part = part[j, part.length - j].to_s
        end
        if part.length > 0
          eq = part.index("=")
          raw_k = eq.nil? ? part : part[0, eq].to_s
          k = decode(raw_k)
          return false if k.nil?
          if eq.nil?
            keys.push(k)
            values.push("")
            present.push(false)
          else
            v = decode(part[eq + 1, part.length - eq - 1].to_s)
            return false if v.nil?
            keys.push(k)
            values.push(v)
            present.push(true)
          end
        end
        i += 1
      end
      true
    end

    # `URI.decode_www_form_component`: `+` is a space, `%XX` a byte, and a
    # `%` not followed by two hex digits is an error (nil), as Ruby raises.
    def self.decode(s)
      out = +""
      i = 0
      n = s.length
      while i < n
        c = s[i]
        if c == "+"
          out << " "
          i += 1
        elsif c == "%"
          return nil if i + 2 >= n
          hi = hex(s[i + 1].to_s)
          lo = hex(s[i + 2].to_s)
          return nil if hi < 0 || lo < 0
          out << (hi * 16 + lo).chr
          i += 3
        else
          out << c.to_s
          i += 1
        end
      end
      out.force_encoding("UTF-8")
    end

    def self.hex(c)
      return c.ord - 48 if c >= "0" && c <= "9"
      return c.ord - 87 if c >= "a" && c <= "f"
      return c.ord - 55 if c >= "A" && c <= "F"
      -1
    end

    # `store_nested_param`, rule for rule. Answers what the reference
    # answers — `params`, a one-element Array for a trailing `[]` below
    # the top, or nil for an empty key — because callers store that
    # answer.
    def self.store(params, name, v, depth)
      raise ParamBuilder::Invalid if depth >= DEPTH_LIMIT
      k = ""
      after = ""
      if depth == 0
        start = name.length > 1 ? name.index("[", 1) : nil
        if start.nil?
          k = name
        else
          k = name[0, start].to_s
          after = name[start, name.length - start].to_s
        end
      elsif name.start_with?("[]")
        k = "[]"
        after = name[2, name.length - 2].to_s
      elsif name.start_with?("[") && !(close = name.index("]", 1)).nil?
        k = name[1, close - 1].to_s
        after = name[close + 1, name.length - close - 1].to_s
      else
        k = name
      end

      return nil if k.empty?
      raise ParamBuilder::Invalid unless k.valid_encoding?
      raise ParamBuilder::Invalid if depth == 0 && !v.nil? && !v.valid_encoding?

      if after == ""
        if k == "[]" && depth != 0
          return v.nil? ? [] : [v]
        end
        params[k] = v
      elsif after == "["
        params[name] = v
      elsif after == "[]"
        params[k] = [] if params[k].nil?
        list = params[k]
        raise ParamBuilder::Invalid unless list.is_a?(Array)
        list.push(v) unless v.nil?
      elsif after.start_with?("[]")
        child = hash_in_array_key(after)
        child = after[2, after.length - 2].to_s if child.nil?
        params[k] = [] if params[k].nil?
        list = params[k]
        raise ParamBuilder::Invalid unless list.is_a?(Array)
        last = list.last
        if last.is_a?(Hash) && !has_key_path?(last, child)
          store(last, child, v, depth + 1)
        else
          list.push(store({}, child, v, depth + 1))
        end
      else
        params[k] = {} if params[k].nil?
        sub = params[k]
        raise ParamBuilder::Invalid unless sub.is_a?(Hash)
        params[k] = store(sub, after, v, depth + 1)
      end
      params
    end

    # `x[][y]`: the `y` of a hash inside an array, when `after` is exactly
    # `[][y]` with no further brackets in `y`; nil otherwise.
    def self.hash_in_array_key(after)
      return nil unless after.length > 4 && after[2] == "[" && after.end_with?("]")
      child = after[3, after.length - 4].to_s
      return nil if child.empty? || !child.index("[").nil? || !child.index("]").nil?
      child
    end

    # `params_hash_has_key?`: does `hash` already hold the bracket path
    # `key` (`b`, `b][c`, …)? A path through `[]` never counts as held.
    def self.has_key_path?(hash, key)
      return false unless key.index("[]").nil?
      h = hash
      parts = key.split(/[\[\]]+/)
      i = 0
      while i < parts.length
        part = parts[i]
        if part != ""
          return false unless h.is_a?(Hash) && h.key?(part)
          h = h[part]
        end
        i += 1
      end
      true
    end

    private_class_method :split, :decode, :hex, :store, :hash_in_array_key, :has_key_path?
  end
end
