# Caching

`Snails.cache` is a process-local key/value store for work that is expensive to repeat: a computed report, an upstream response, a counter window. It is not a shared cache — every process has its own copy, and a value never leaves the process that wrote it.

## Store and fetch

```ruby
report = Snails.cache.fetch("reports/#{id}", expires_in: 60) { build_report(id) }

Snails.cache.write("settings", settings, expires_in: 5.minutes)
settings = Snails.cache.read("settings")

Snails.cache.exist?("settings")
Snails.cache.delete("settings")
Snails.cache.clear
```

`fetch` returns the stored value, or runs the block once on a miss and stores its result. A stored `nil` is a valid entry: a block that returns `nil` is not re-run. `write` answers `true`; `read` answers `nil` on a miss or after expiry; `delete` answers `true` only when a live entry was removed.

Keys are strings; a key object that responds to `to_s` is stringified. An expiry accepts an Integer count of seconds or a `Snails::Duration`; a positive value is required, and `nil` means the entry never expires. `0` and a negative value raise.

`increment` is the counter half. The first write in a window starts the counter and applies its expiry; later increments keep that expiry, which is what makes a fixed window:

```ruby
count = Snails.cache.increment("signup/#{ip}", 1, expires_in: 1.hour)
```

`amount` must be an Integer; a stored non-Integer value is read through `to_i` on the first increment.

## The store is bounded

The cache holds at most 5,000 entries. When a write would add a new key at the limit, the store clears every entry before writing the new one. It is a finite store, not an LRU: the bound keeps growth finite and the flush is the cheap answer, but a burst of distinct keys can drop values other requests were using.

Size the key space and expiry for that behavior. A cache keyed by a request field with no expiry reaches the bound fastest.

## The process boundary

The cache belongs to the process. Two server processes, a prefork child, and a separate container all have separate stores. A value written while serving one request is not visible to another process, so anything that must be shared belongs in the database.

A development restart clears the cache. `bin/test` clears it before each case, so a cached value or counter never leaks into the next test.

`fetch` misses run their block outside the store's lock, so two threads that miss the same key can both compute; the later write wins. That is duplicate work, not a wrong value. Counters are the exception: `increment` is one locked read-modify-write.

HTTP caching is separate. The runtime does not write `Cache-Control` or validators for you; set `headers["Cache-Control"]` (or `ETag`, `Last-Modified`) in the action when a proxy or client should cache the response. The cache above is server-side and does not affect response headers.

[Time, Dates, and JSON](17-time-dates-and-json.md) covers the `Duration` values an expiry can take.
