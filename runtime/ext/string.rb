# String — the text helpers.
class String
  # whitespace runs collapse to one space and the ends strip: the shape
  # `<<~SQL.squish` produces. The scan is spelled out because a regex is not a
  # form the compiler lowers.
  #
  # @return [String] this text with whitespace runs folded to one space and
  #   the ends stripped
  def squish
    out = +""
    pending_space = false
    i = 0
    while i < length
      c = self[i]
      if c == " " || c == "\t" || c == "\n" || c == "\r" || c == "\f" || c == "\v"
        pending_space = !out.empty?
      else
        out = out + " " if pending_space
        pending_space = false
        out = out + c
      end
      i = i + 1
    end
    out
  end

  # `"FooBar"` → `"foo_bar"`: camel boundaries split, `-` reads as `_`, the
  # result downcased. The walk is spelled out rather than a regex pipeline, and
  # no acronym or human-name table is modeled.
  #
  # @return [String] the underscored, downcased form of this text
  def underscore
    s = to_s
    out = +""
    n = s.length
    i = 0
    while i < n
      c = s[i].to_s
      if c >= "A" && c <= "Z" && i > 0
        prev = s[i - 1].to_s
        nxt = i + 1 < n ? s[i + 1].to_s : ""
        prev_lower = (prev >= "a" && prev <= "z") || (prev >= "0" && prev <= "9")
        prev_upper = prev >= "A" && prev <= "Z"
        next_lower = nxt >= "a" && nxt <= "z"
        out << "_" if prev_lower || (prev_upper && next_lower)
      end
      out << (c == "-" ? "_" : c)
      i = i + 1
    end
    out.downcase
  end

  # `"host_info"` → `"HostInfo"`, or `"hostInfo"` with `mode: :lower`:
  # underscore-separated words capitalized, a `/` read as a namespace separator
  # (`"a/b"` → `"A::B"`). The shape JSON keys need when a payload is camelCase.
  #
  # @param mode [Symbol] `:upper` capitalizes the leading word, `:lower`
  #   decamels it
  # @return [String] the camelCase form of this text
  # @raise [ArgumentError] mode is neither `:upper` nor `:lower`
  # @example
  #   "host_info".camelize           # => "HostInfo"
  #   "host_info".camelize(:lower)   # => "hostInfo"
  def camelize(mode = :upper)
    unless mode == :upper || mode == :lower
      raise ArgumentError, "camelize expects :upper or :lower, got #{mode.inspect}"
    end

    out = +""
    i = 0
    n = length
    at_word_start = true
    first_word = true
    downcase_rest = false
    while i < n
      c = self[i].to_s
      if c == "_" || c == "/"
        out << "::" if c == "/"
        at_word_start = true
        first_word = false
        downcase_rest = true
      elsif at_word_start
        out << (mode == :lower && first_word ? c.downcase : c.upcase)
        at_word_start = false
        downcase_rest = !first_word
        first_word = false
      elsif downcase_rest
        out << c.downcase
      else
        out << c
      end
      i = i + 1
    end
    out
  end

  # `"foo_bar"` → `"Foo bar"`: underscores to spaces, a trailing " id" dropped,
  # first letter upcased.
  #
  # @return [String] this text in sentence case
  def humanize
    s = to_s.tr("_", " ").lstrip
    s = s[0, s.length - 3].to_s if s.end_with?(" id")
    s = s.downcase
    return s if s.empty?
    s[0].to_s.upcase + s[1, s.length - 1].to_s
  end

  # `"foo_bar"` → `"Foo Bar"`: each word's first letter upcased.
  #
  # @return [String] this text in title case
  def titleize
    s = underscore.humanize
    out = +""
    n = s.length
    i = 0
    while i < n
      c = s[i].to_s
      prev = i > 0 ? s[i - 1].to_s : ""
      word_prev = (prev >= "a" && prev <= "z") || (prev >= "A" && prev <= "Z") || (prev >= "0" && prev <= "9") || prev == "_"
      out << (c >= "a" && c <= "z" && !word_prev ? c.upcase : c)
      i = i + 1
    end
    out
  end

  # the plural of this word, or the word unchanged when `count == 1`: the word a
  # count labels, singular for one item and plural for every other count.
  #
  # The suffix rules are the regular English ones, not the full
  # irregular tables: a consonant before "y" turns to "ies"
  # ("category"), "x", "z", "ch" and "sh" take "es" ("box", "church"),
  # and a word that already ends in "s" keeps its form ("posts").
  #
  # @param count [Integer] how many items the word labels
  # @return [String] the word unchanged for one item, its plural otherwise
  # @example
  #   "post".pluralize(1)      # => "post"
  #   "post".pluralize(2)      # => "posts"
  #   "category".pluralize(3)  # => "categories"
  def pluralize(count)
    return self if count == 1
    n = length
    return "s" if n == 0
    last = self[n - 1, 1].to_s
    if last == "y" && n > 1
      prev = self[n - 2, 1].to_s
      if prev == "a" || prev == "e" || prev == "i" || prev == "o" || prev == "u"
        self + "s"
      else
        self[0, n - 1].to_s + "ies"
      end
    elsif last == "s"
      self
    elsif last == "x" || last == "z"
      self + "es"
    elsif n > 1 && (self[n - 2, 2].to_s == "ch" || self[n - 2, 2].to_s == "sh")
      self + "es"
    else
      self + "s"
    end
  end

  # this text as a URL slug: downcased, with every run of characters outside
  # `a-z`, `0-9` and "_" folded into a single "-", runs of "-" collapsed, and
  # "-" trimmed off both ends.
  #
  # Letters outside ASCII are dropped rather than transliterated, so a
  # non-Latin word parameterizes to an empty string.
  #
  # @return [String] the slug form of this text
  # @example
  #   "Hello World".parameterize  # => "hello-world"
  #   "a  b".parameterize         # => "a-b"
  def parameterize
    s = downcase
    out = +""
    # A separator run waits for the next kept character — that is what trims
    # a leading or trailing "-" without a second pass over the text.
    pending_separator = false
    i = 0
    n = s.length
    while i < n
      c = s[i].to_s
      if (c >= "a" && c <= "z") || (c >= "0" && c <= "9") || c == "_"
        out << "-" if pending_separator && !out.empty?
        pending_separator = false
        out << c
      else
        pending_separator = true
      end
      i = i + 1
    end
    out
  end

  # `"2024-01-02 03:04:05.000006"` → the instant, in the app's configured zone:
  # a stored datetime column read back. Text too short to carry an instant reads
  # nil. The parse is the stored form's fixed width, not a date-parser pipeline:
  # the storage form is the contract, and the micros stay in `Time.utc`'s
  # seventh argument (a float added afterwards loses a microsecond and skews
  # `> ?` bounds). The zone comes from the process TZ, which
  # `config/environment.rb` pins, so the answer arrives in the app zone without
  # a lookup.
  #
  # @return [Time?] the parsed instant, or nil when the text cannot carry one
  def to_time
    return nil if length < 19
    micros = 0
    if length > 20 && self[19, 1] == "."
      digits = 0
      while digits < 6
        c = self[20 + digits, 1]
        break if c.nil? || c.empty? || c < "0" || c > "9"
        # `+ 1`, not `+=`: spinel rejects local operator-assignment.
        digits = digits + 1
      end
      if digits > 0
        micros = "#{self[20, digits]}000000"[0, 6].to_i
      end
    end
    t = Time.utc(
      self[0, 4].to_i, self[5, 2].to_i, self[8, 2].to_i,
      self[11, 2].to_i, self[14, 2].to_i, self[17, 2].to_i, micros
    )
    t.getlocal
  end
end
