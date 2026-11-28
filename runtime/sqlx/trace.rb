# frozen_string_literal: true

# DB spans at the four statement entries. The helper owns the low-cardinality
# SQL summary and the attribute contract; the adapter owns the connection and
# the driver call.
#
# The summary never carries a bound value. `db.query.text` is opt-in and only
# for the caller's parameterized SQL, so a statement whose values were rendered
# by the adapter never reaches the wire.
module Sqlx
  module Trace
    # The SQL words a span name may carry. An unknown first word (a statement
    # that is not SQL, or a dialect extension) becomes UNKNOWN, so a value or a
    # typo never lands in a low-cardinality name.
    KNOWN_OPERATIONS = "SELECT INSERT UPDATE DELETE CREATE ALTER DROP PRAGMA WITH REPLACE TRUNCATE EXPLAIN VACUUM ATTACH DETACH BEGIN COMMIT ROLLBACK".split(" ")

    # Run one statement inside a DB span. Tracing off or a trace that is not
    # sampled yields nil and the block runs without span work; the block's
    # return value is preserved.
    #
    # @param sql [String] the statement as the caller wrote it
    # @param system [String] `sqlite` or `postgresql`
    # @param parameterized [Boolean] true when `sql` carries `?` placeholders
    # @yieldparam span [Snails::Tracer::Span, nil] the DB span, or nil
    # @yieldreturn [Object] the adapter's result
    # @return [Object] the block's return value
    def self.span(sql, system, parameterized = false)
      return yield(nil) unless Snails.tracer.enabled?

      parts = summary_parts(sql)
      operation = parts[0]
      collection = parts[1]
      name = collection.empty? ? operation : operation + " " + collection
      attributes = {
        "db.system.name" => system,
        "db.operation.name" => operation,
        "db.query.summary" => name
      }
      attributes["db.collection.name"] = collection unless collection.empty?
      if parameterized && Snails.tracer.db_query_text && sql.include?("?")
        attributes["db.query.text"] = sql
      end

      span = Snails.tracer.start_span(name, kind: :client, attributes: attributes)
      return yield(nil) if span.nil?

      begin
        result = yield(span)
        span.set_status(:ok)
        result
      rescue Exception => failure
        span.record_exception(failure)
        raise
      ensure
        span.finish
      end
    end

    # Add one span attribute without a nil guard at every call site.
    #
    # @param span [Snails::Tracer::Span, nil] the DB span
    # @param key [String] the attribute name
    # @param value [Object] the attribute value
    # @return [void]
    def self.add_attribute(span, key, value)
      return if span.nil?

      span.set_attribute(key, value)
    end

    # The SQL operation and the first collection, both without values. DML
    # with a subquery before its table target reports the operation alone.
    def self.summary_parts(sql)
      text = sql.to_s
      i = skip_space(text, 0)
      start = i
      i = word_end(text, i)
      operation = text[start, i - start].to_s.upcase
      if !known_operation?(operation)
        operation = "UNKNOWN"
      end

      collection = ""
      if operation == "SELECT"
        at = find_keyword(text, i, "FROM")
        if at >= 0 && !subquery_before?(text, i, at)
          collection = collection_token(text, at + 4)
        end
      elsif operation == "INSERT"
        at = find_keyword(text, i, "INTO")
        collection = collection_token(text, at + 4) if at >= 0
      elsif operation == "UPDATE"
        collection = collection_token(text, i)
      elsif operation == "DELETE"
        at = find_keyword(text, i, "FROM")
        collection = collection_token(text, at + 4) if at >= 0
      end
      [operation, collection]
    end

    def self.known_operation?(operation)
      i = 0
      while i < KNOWN_OPERATIONS.length
        return true if KNOWN_OPERATIONS[i] == operation
        i += 1
      end
      false
    end

    def self.skip_space(text, from)
      i = from
      while i < text.length && text.getbyte(i) <= 32
        i += 1
      end
      i
    end

    def self.word_end(text, from)
      i = from
      while i < text.length
        byte = text.getbyte(i)
        break if byte <= 32 || byte == 40 || byte == 59
        i += 1
      end
      i
    end

    def self.find_keyword(text, from, keyword)
      i = from
      while i < text.length
        return i if keyword_match?(text, i, keyword)
        i += 1
      end
      -1
    end

    def self.keyword_match?(text, at, keyword)
      return false if at + keyword.length > text.length
      return false unless text[at, keyword.length].to_s.upcase == keyword

      before = at == 0 ? 32 : text.getbyte(at - 1)
      after = text.getbyte(at + keyword.length)
      before_ok = before <= 32 || before == 40
      after_ok = after.nil? || after <= 32 || after == 40 || after == 59
      before_ok && after_ok
    end

    # A nested SELECT/WITH before the outer FROM means the first FROM belongs
    # to a subquery; the summary drops the collection rather than naming the
    # wrong one.
    def self.subquery_before?(text, from, upto)
      i = from
      while i < upto
        if text.getbyte(i) == 40
          j = skip_space(text, i + 1)
          return true if keyword_match?(text, j, "SELECT") || keyword_match?(text, j, "WITH")
        end
        i += 1
      end
      false
    end

    # The identifier after a keyword or operation. A quoted name keeps its
    # inside text; an unquoted name stops at whitespace, a paren, comma, or
    # semicolon.
    def self.collection_token(text, from)
      i = skip_space(text, from)
      return "" if i >= text.length

      first = text.getbyte(i)
      if first == 34 || first == 96
        i += 1
        start = i
        while i < text.length && text.getbyte(i) != first
          i += 1
        end
        return text[start, i - start].to_s
      end

      start = i
      while i < text.length
        byte = text.getbyte(i)
        break if byte <= 32 || byte == 40 || byte == 44 || byte == 59
        i += 1
      end
      text[start, i - start].to_s
    end

    private_constant :KNOWN_OPERATIONS
    private_class_method :known_operation?, :summary_parts, :skip_space, :word_end
    private_class_method :find_keyword, :keyword_match?, :subquery_before?
    private_class_method :collection_token
  end
end
