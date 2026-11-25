# Caching

`Snails.cache` is a per-process key/value store for work that is expensive to repeat: a computed report, an upstream response, a counter window. It isn't a shared cache — every process has its own copy, and a value never leaves the process that wrote it.

## Store and fetch

```ruby
report = Snails.cache.fetch("reports/#{id}", expires_in: 60) { build_report(id) }

Snails.cache.write("settings", settings, expires_in: 5.minutes)
settings = Snails.cache.read("settings")

Snails.cache.exist?("settings")
Snails.cache.delete("settings")
Snails.cache.clear
```

`fetch` returns the stored value, or runs the block once on a miss and stores its result. A stored `nil` is a valid entry: a block that returns `nil` isn't re-run. `write` returns `true`. `read` returns `nil` on a miss or after expiry. `delete` returns `true` only when a live entry was removed.

Keys are strings. A key object that responds to `to_s` is stringified. An expiry accepts an Integer count of seconds or a `Snails::Duration`. A positive value is required, and `nil` means the entry never expires. `0` and a negative value raise.

The counter operation is `increment`. The first write in a window starts the counter and applies its expiry. Later increments keep that expiry, which is what makes a fixed window:

```ruby
count = Snails.cache.increment("signup/#{ip}", 1, expires_in: 1.hour)
```

`amount` must be an Integer. A stored non-Integer value is read through `to_i` on the first increment.

## The store is bounded

The cache holds at most 5,000 entries. A write that adds a new key at the limit clears every entry first, then stores the new key. That keeps memory bounded, but it is not an LRU: a burst of distinct keys can drop values other requests were using.

Size the key space and expiry for that behavior. A cache keyed by a request field with no expiry reaches the bound fastest.

## The process boundary

The cache belongs to the process. Two server processes or two containers have separate stores. A value written while serving one request isn't visible to another process, so anything that must be shared belongs in the database.

A development restart clears the cache. `bin/test` clears it before each case, so a cached value or counter never leaks into the next test.

`fetch` misses run their block outside the store's lock, so two threads that miss the same key can both compute. The later write wins. That is duplicate work, not a wrong value. Counters are the exception: `increment` is one locked read-modify-write.

HTTP caching is separate. The framework doesn't write `Cache-Control` or validators for you. Set `headers["Cache-Control"]` (or `ETag`, `Last-Modified`) in the action when a proxy or client should cache the response. The cache above is server-side and doesn't affect response headers.

[Time, Dates, and JSON](17-time-dates-and-json.md) covers the `Duration` values an expiry can take.
