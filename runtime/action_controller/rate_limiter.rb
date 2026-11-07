# The question behind `rate_limit to: 10, within: 3.minutes`: has this key
# been seen more than `to` times in the current window?
#
#   exceeded?  =  the window's count, after this request, > to
#
# The count lives in `Snails.cache` under the key the lowering builds —
# `rate-limit:<controller_path>[:<name>]:<by>` — and the window is the
# entry's TTL: the first request in a window writes it with `within` seconds
# to live, and every later one increments it until it expires.
#
# Called from the private method the `rate_limit` lowering synthesizes; the
# `with:` block — what to do when the answer is yes — is the app's, and runs
# in that method.

module ActionController
  module RateLimiter
    def self.exceeded?(key, within, to)
      Snails.cache.increment(key, expires_in: within) > to
    end
  end
end
