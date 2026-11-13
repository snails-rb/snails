# The process-local cache: one instance per process, not shared across prefork
# workers; expiry is lazy, the store flushes at a bound, and nil is a valid entry.
#
# With no global VM lock, the lock must cover compound operations, and `fetch`
# runs its block outside it, so two misses may compute the same value.
module Snails
  # the process-wide store, memoized so every call answers the same instance (a
  # fresh `Cache.new` would make every `fetch` a miss).
  #
  # @return [Cache]
  def self.cache
    @cache_store ||= Cache.new
  end

  class Cache
    # Entry cap. Reaching it flushes the whole store: the bound keeps
    # growth finite rather than hitting a byte target, and a count avoids
    # measuring every stored value.
    MAX_ENTRIES = 5000

    # Distinguishes "no entry" from a stored nil value.
    MISSING = Object.new

    def initialize
      @entries = {}
      @expires_at = {}
      @lock = Mutex.new
    end

    # return the cached value, or run the block and store its result. A miss and
    # a stored nil are different: the hit test uses an internal sentinel, so a
    # nil-valued entry is not recomputed.
    #
    # @param key [String] the cache key
    # @param expires_in [Integer, Snails::Duration, nil] seconds until
    #   expiry; nil never expires
    # @return [Object] the stored value, or the block's result on a miss
    # @raise [ArgumentError] the block is missing or `expires_in` is not positive
    # @example
    #   Snails.cache.fetch("reports/#{id}", expires_in: 60) { build_report(id) }
    def fetch(key, expires_in: nil)
      unless block_given?
        raise ArgumentError, "fetch requires a block"
      end
      seconds = expires_in_seconds(expires_in)
      k = key.to_s
      hit = read_entry(k)
      return hit unless hit.equal?(MISSING)
      value = yield
      write_entry(k, value, seconds)
      value
    end

    # the stored value, or nil on a miss or after expiry.
    #
    # @param key [String] the cache key
    # @return [Object, nil]
    def read(key)
      hit = read_entry(key.to_s)
      hit.equal?(MISSING) ? nil : hit
    end

    # store a value.
    #
    # @param key [String] the cache key
    # @param value [Object] the value to store; nil is a valid entry
    # @param expires_in [Integer, Snails::Duration, nil] seconds until
    #   expiry; nil never expires
    # @return [Boolean] true when the value was stored
    # @raise [ArgumentError] `expires_in` is not positive
    def write(key, value, expires_in: nil)
      write_entry(key.to_s, value, expires_in_seconds(expires_in))
      true
    end

    # remove one entry.
    #
    # @param key [String] the cache key
    # @return [Boolean] true when a live entry was removed; an expired entry
    #   counts as absent and is purged
    def delete(key)
      k = key.to_s
      removed = false
      @lock.synchronize do
        if @entries.key?(k)
          removed = !expired?(@expires_at[k])
          @entries.delete(k)
          @expires_at.delete(k)
        end
      end
      removed
    end

    # whether a live entry is stored.
    #
    # @param key [String] the cache key
    # @return [Boolean] false when missing or expired; the expired entry is
    #   purged
    def exist?(key)
      !read_entry(key.to_s).equal?(MISSING)
    end

    # add to a counter. The first write in a window starts it: a new entry is
    # stored with `expires_in`, and later increments keep that expiry (a
    # rate-limit window). A non-integer value is read through `to_i`.
    #
    # @param key [String] the cache key
    # @param amount [Integer] the increase
    # @param expires_in [Integer, Snails::Duration, nil] seconds until
    #   expiry for a new entry; nil never expires
    # @return [Integer] the value after the increase
    # @raise [ArgumentError] `amount` is not an Integer or `expires_in` is not
    #   positive
    def increment(key, amount = 1, expires_in: nil)
      unless amount.is_a?(Integer)
        raise ArgumentError, "amount must be an Integer, got #{amount.class}"
      end
      seconds = expires_in_seconds(expires_in)
      k = key.to_s
      result = amount
      @lock.synchronize do
        if @entries.key?(k) && !expired?(@expires_at[k])
          result = @entries[k].to_i + amount
          @entries[k] = result
        else
          flush_if_full unless @entries.key?(k)
          @entries[k] = amount
          @expires_at[k] = seconds == 0 ? 0 : Time.now.to_i + seconds
        end
      end
      result
    end

    # remove every entry. The harness calls this before each case so cache
    # values and rate-limit windows do not leak across tests.
    #
    # @return [void]
    def clear
      @lock.synchronize do
        @entries.clear
        @expires_at.clear
      end
    end

    # Convert `expires_in` to whole seconds; 0 means "never expires".
    def expires_in_seconds(expires_in)
      return 0 if expires_in.nil?
      unless expires_in.is_a?(Integer) || expires_in.is_a?(Snails::Duration)
        raise ArgumentError, "expires_in must be Integer seconds or a Duration, got #{expires_in.class}"
      end
      seconds = expires_in.to_i
      if seconds <= 0
        raise ArgumentError, "expires_in must be positive seconds, got #{expires_in.inspect}"
      end
      seconds
    end

    def expired?(due)
      due != 0 && due <= Time.now.to_i
    end

    # One locked read for `read`, `exist?`, and `fetch` — purges an expired
    # entry and answers the sentinel on a miss.
    def read_entry(k)
      hit = MISSING
      @lock.synchronize do
        if @entries.key?(k)
          due = @expires_at[k]
          if expired?(due)
            @entries.delete(k)
            @expires_at.delete(k)
          else
            hit = @entries[k]
          end
        end
      end
      hit
    end

    def write_entry(k, value, seconds)
      @lock.synchronize do
        flush_if_full unless @entries.key?(k)
        @entries[k] = value
        @expires_at[k] = seconds == 0 ? 0 : Time.now.to_i + seconds
      end
      value
    end

    def flush_if_full
      if @entries.size >= MAX_ENTRIES
        @entries.clear
        @expires_at.clear
      end
    end

    private :expires_in_seconds, :expired?, :read_entry, :write_entry, :flush_if_full
  end
end
