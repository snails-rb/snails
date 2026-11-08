# The request-scoped read cache both database adapters share. Every connection
# checked out inside a `with_connection` scope runs inside one: an identical
# SELECT replays the first result, and any write or DDL invalidates it. The
# cache lives on the scope's thread/fiber, never on a connection, so two
# requests never share rows.
#
# The store never looks at statement text — the cache KEY is adapter-owned,
# any string that covers the SQL and its bind values. The contract is the
# same on every backend: a bound read is cached per value rather than
# skipped, one statement holds at most `QueryCache::ROWS` rows, a request
# holds at most `QueryCache::ENTRIES` statements, and rows are copied on
# store and on the way out so a caller mutating a returned row cannot
# poison a later hit.
#
# Invalidation is generation-based and process-wide: a write bumps the
# generation, and an entry stored under an older generation is never
# replayed. A write on one thread therefore cannot leave another thread's
# scope holding pre-write rows, and an in-flight read cannot publish its
# pre-write result after the write it raced.

module Sqlx
  # One cached SELECT result: the rows plus the cache generation the read
  # started in. The generation is captured before the statement executes, so a
  # write that lands while the read is in flight cannot publish pre-write rows
  # under the new generation.
  class QueryCacheEntry
    # one cached SELECT result: the rows and the cache generation the read
    # started in.
    #
    # @param generation [Integer] the generation captured before the read
    #   executed
    # @param rows [Array] one name-keyed row per cached result row
    # @return [void]
    def initialize(generation, rows)
      @generation = generation
      @rows = rows
    end

    # the cache generation the entry belongs to.
    #
    # @return [Integer] the process cache generation at store time
    def generation
      @generation
    end

    # the cached name-keyed rows.
    #
    # @return [Array] one name-keyed row per cached result row
    def rows
      @rows
    end
  end

  # One request's read cache, created when the outermost `with_connection`
  # scope first checks a connection out and dropped when that scope ends.
  class QueryCache
    # A cached statement holds at most this many rows. The cache exists for
    # the point lookup a page repeats; copying a large scan would pay for
    # rows nothing ever replays.
    ROWS = 16
    # The per-request entry cap; past it new statements ride uncached.
    ENTRIES = 128

    # an empty read cache for one request scope.
    #
    # @return [void]
    def initialize
      @entries = {}
    end

    # the cached rows for `key` when the entry was stored under the same cache
    # generation, else nil. Rows are copied out so a caller mutating a returned
    # row cannot change what a later hit replays.
    #
    # @param key [String] the statement's cache key — SQL plus its bind values
    # @param generation [Integer] the cache generation the read started in
    # @return [Array, nil] one name-keyed row per cached result row; nil when
    #   the entry is absent or belongs to an older generation
    # @example
    #   cache.fetch_cached_rows("SELECT id FROM t WHERE id = 1", 7)
    #   # => [ { "id" => 1 } ]
    def fetch_cached_rows(key, generation)
      entry = @entries[key]
      return nil if entry.nil?
      return nil unless entry.generation == generation
      copy_rows(entry.rows)
    end

    # cache a completed result. A result larger than ROWS is skipped, as is a
    # new key once the cache is full. The adapter checks the generation
    # immediately before this call, so an entry that races a write is never
    # published under the new generation.
    #
    # @param key [String] the statement's cache key — SQL plus its bind values
    # @param rows [Array] one name-keyed row per result row
    # @param generation [Integer] the cache generation the read started in
    # @return [void]
    # @example
    #   cache.store_cached_rows("SELECT id FROM t WHERE id = 1", [ { "id" => 1 } ], 7)
    def store_cached_rows(key, rows, generation)
      return nil if rows.length > ROWS
      return nil if !@entries.key?(key) && @entries.length >= ENTRIES
      @entries[key] = QueryCacheEntry.new(generation, copy_rows(rows))
    end

    # drop every entry. The generation check already makes them unreachable;
    # clearing releases the rows now instead of at lease end.
    #
    # @return [void]
    # @example
    #   cache.clear_cached_rows
    def clear_cached_rows
      @entries = {}
    end

    # Rows and their String values copied, so the cache owns its rows
    # independently of the caller's result.
    def copy_rows(rows)
      copy = []
      rows.each do |row|
        out = {}
        row.each do |key, value|
          out[key] = value.is_a?(String) ? value.dup : value
        end
        copy.push(out)
      end
      copy
    end

    private :copy_rows
  end

  # The cache's module surface, part of the adapter contract both backends
  # satisfy. The adapters call these from `exec_read` (fetch/store), `exec` /
  # `exec_write` / `configure` (invalidate), and `with_connection` (scope
  # lifetime).
  module Database
    # The request read cache is per scope (thread/fiber); its generation is
    # process-wide so a write on any thread invalidates every thread's
    # entries. The lock serializes generation increments — two writes must not
    # collapse into the same value and leave an in-flight read's entry
    # looking current.
    @query_cache_generation = 0
    @query_cache_lock = Mutex.new

    # open a fresh cache for this scope. Called when the outermost scope first
    # checks a connection out; a nested scope shares the outer cache.
    #
    # @return [void]
    def self.query_cache_begin
      Thread.current[:sqlx_query_cache] = QueryCache.new
    end

    # drop this scope's cache. The rows are request scoped; nothing survives the
    # outermost scope.
    #
    # @return [void]
    def self.query_cache_end
      Thread.current[:sqlx_query_cache] = nil
    end

    # invalidate every thread's entries after a write or DDL. The generation
    # bump is serialized: two writes landing together must not collapse into one
    # value and leave a pre-write entry looking current.
    #
    # @return [void]
    def self.query_cache_clear
      @query_cache_lock.synchronize do
        @query_cache_generation = @query_cache_generation + 1
      end
      cache = Thread.current[:sqlx_query_cache]
      cache.clear_cached_rows unless cache.nil?
    end

    # the cached rows for the statement when this lease stored them under the
    # same generation, else nil. A thread outside a scope has no cache.
    #
    # @return [Array, nil]
    def self.query_cache_fetch(key, generation)
      cache = Thread.current[:sqlx_query_cache]
      return nil if cache.nil?
      cache.fetch_cached_rows(key, generation)
    end

    # cache a completed result when the generation is still the one the read
    # started in. A write that landed while the read ran leaves the result
    # uncached instead of publishing stale rows under the new generation.
    #
    # @return [void]
    def self.query_cache_store(key, rows, generation)
      cache = Thread.current[:sqlx_query_cache]
      return nil if cache.nil?
      return nil unless generation == @query_cache_generation
      cache.store_cached_rows(key, rows, generation)
    end

    # whether `sql` is a plain SELECT this cache may hold. A locking read is not
    # cached, and a WITH query or a write stays uncached too: this is a keyword
    # check for the reads core emits, not a SQL parser. SQLite has no locking
    # reads, so the checks there are harmless no-ops.
    #
    # @return [Boolean]
    def self.select_read?(sql)
      i = 0
      while i < sql.length
        c = sql[i, 1]
        if c == " " || c == "\t" || c == "\n" || c == "\r"
          i += 1
        else
          break
        end
      end
      head = sql[i, 6]
      return false if head.nil?
      return false unless head.upcase == "SELECT"
      return false if sql.include?("FOR UPDATE")
      return false if sql.include?("FOR NO KEY UPDATE")
      return false if sql.include?("FOR SHARE")
      return false if sql.include?("FOR KEY SHARE")
      true
    end

    # the trace line for a replay. It logs the statement as written
    # (placeholders, not values), so the cache key's bound values never reach
    # the log.
    #
    # @return [void]
    def self.record_cache_hit(sql)
      $stderr.puts "  CACHE " + sql if @sql_trace
    end

    private_class_method :query_cache_begin, :query_cache_end
    private_class_method :query_cache_fetch, :query_cache_store
    private_class_method :select_read?, :record_cache_hit
  end
end
