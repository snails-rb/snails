# The question behind `rate_limit to: 10, within: 3.minutes`: has this key
# been seen more than `to` times in the current window?
# The count lives in `Snails.cache` under the key the lowering builds, and
# the window is the entry's TTL: the first request sets it, later ones
# increment it. The method the lowering synthesizes calls this and runs `with:`.

module ActionController
  module RateLimiter
    def self.exceeded?(key, within, to)
      Snails.cache.increment(key, expires_in: within) > to
    end
  end
end
