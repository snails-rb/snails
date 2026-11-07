require_relative "test_helper"
require_relative "harness_runner"

# `Snails.cache` — the process-local store shared by cached values, counters,
# and invalidation. These cases pin the public contract: fetch caches a
# block's result (including nil and an empty string), a TTL expires
# lazily, `increment` keeps the window opened by its first write, and
# `delete`/`clear` invalidate.
class SnailsCacheTest < TestBase
  def assert_equal(expected, actual, msg = nil)
    raise(msg || "expected #{expected.inspect}, got #{actual.inspect}") unless expected == actual
  end

  def assert_argument_error
    raised = false
    begin
      yield
    rescue ArgumentError
      raised = true
    end
    assert_equal true, raised
  end

  def setup
    Snails.cache.clear
  end

  # A miss runs the block and stores its value; a hit answers from the
  # store without running the block again.
  def test_fetch_misses_then_hits
    runs = 0
    first = Snails.cache.fetch("snails-cache:memo", expires_in: 60) do
      runs = runs + 1
      "rendered"
    end
    second = Snails.cache.fetch("snails-cache:memo", expires_in: 60) do
      runs = runs + 1
      "rerendered"
    end
    assert_equal "rendered", first
    assert_equal "rendered", second
    assert_equal 1, runs
  end

  # A stored nil is a hit: the entry exists, so `fetch` answers nil without
  # running the block again.
  def test_fetch_caches_a_nil_value
    runs = 0
    Snails.cache.fetch("snails-cache:nil", expires_in: 60) do
      runs = runs + 1
      nil
    end
    value = Snails.cache.fetch("snails-cache:nil", expires_in: 60) do
      runs = runs + 1
      "rebuilt"
    end
    assert_equal nil, value
    assert_equal 1, runs
    assert_equal true, Snails.cache.exist?("snails-cache:nil")
  end

  # An empty String is a hit — a value can legitimately be empty, and
  # treating it as a miss would re-run the block on every call.
  def test_empty_string_is_a_hit
    Snails.cache.write("snails-cache:empty", "", expires_in: 60)
    found = false
    value = Snails.cache.fetch("snails-cache:empty", expires_in: 60) do
      found = true
      "rebuilt"
    end
    assert_equal "", value
    assert_equal false, found
  end

  # write stores a value and read returns it; a missing key reads nil.
  def test_write_and_read
    assert_equal true, Snails.cache.write("snails-cache:value", "stored", expires_in: 60)
    assert_equal "stored", Snails.cache.read("snails-cache:value")
    assert_equal nil, Snails.cache.read("snails-cache:missing")
  end

  # exist? answers presence; delete answers whether a live entry was removed
  # and a second delete answers false.
  def test_exist_and_delete
    Snails.cache.write("snails-cache:delete", "value", expires_in: 60)
    assert_equal true, Snails.cache.exist?("snails-cache:delete")
    assert_equal true, Snails.cache.delete("snails-cache:delete")
    assert_equal false, Snails.cache.exist?("snails-cache:delete")
    assert_equal false, Snails.cache.delete("snails-cache:delete")
  end

  # The counter starts at the first amount and counts up; a deleted key
  # starts a fresh window.
  def test_increment_counts
    assert_equal 1, Snails.cache.increment("snails-cache:count", expires_in: 60)
    assert_equal 2, Snails.cache.increment("snails-cache:count", expires_in: 60)
    assert_equal 3, Snails.cache.increment("snails-cache:count", expires_in: 60)
    Snails.cache.delete("snails-cache:count")
    assert_equal 5, Snails.cache.increment("snails-cache:count", 5, expires_in: 60)
    assert_equal 6, Snails.cache.increment("snails-cache:count", expires_in: 60)
  end

  # delete invalidates one key, clear empties the whole store, and a
  # missing key reads nil.
  def test_delete_and_clear
    Snails.cache.write("snails-cache:a", "a", expires_in: 60)
    Snails.cache.write("snails-cache:b", "b", expires_in: 60)
    Snails.cache.delete("snails-cache:a")
    assert_equal nil, Snails.cache.read("snails-cache:a")
    assert_equal "b", Snails.cache.read("snails-cache:b")
    Snails.cache.clear
    assert_equal nil, Snails.cache.read("snails-cache:b")
  end

  # An entry past its TTL reads as a miss, is absent, and is recomputed by
  # fetch.
  def test_expired_entry_is_a_miss
    Snails.cache.write("snails-cache:short", "value", expires_in: 1)
    sleep 1.2
    assert_equal nil, Snails.cache.read("snails-cache:short")
    assert_equal false, Snails.cache.exist?("snails-cache:short")
    runs = 0
    value = Snails.cache.fetch("snails-cache:short", expires_in: 60) do
      runs = runs + 1
      "rebuilt"
    end
    assert_equal "rebuilt", value
    assert_equal 1, runs
  end

  # A non-positive expiry is rejected at the entry point.
  def test_expires_in_must_be_positive
    assert_argument_error do
      Snails.cache.write("snails-cache:bad", "value", expires_in: 0)
    end
  end

  # A Duration is accepted as an expiry.
  def test_accepts_duration_expiry
    Snails.cache.write("snails-cache:duration", "value", expires_in: 60.seconds)
    assert_equal "value", Snails.cache.read("snails-cache:duration")
  end

  # A non-numeric expiry is rejected at the entry point.
  def test_expires_in_must_be_seconds_or_duration
    assert_argument_error do
      Snails.cache.write("snails-cache:bad", "value", expires_in: "60")
    end
  end

  # fetch without a block is rejected at the entry point.
  def test_fetch_requires_a_block
    assert_argument_error do
      Snails.cache.fetch("snails-cache:noblock")
    end
  end

  # Concurrent increments are counted exactly — the store lock covers the
  # read-modify-write.
  def test_concurrent_increment
    threads = []
    i = 0
    while i < 8
      threads.push(Thread.new do
        n = 0
        while n < 100
          Snails.cache.increment("snails-cache:threads", expires_in: 60)
          n = n + 1
        end
      end)
      i = i + 1
    end
    threads.each { |t| t.join }
    assert_equal 800, Snails.cache.read("snails-cache:threads")
  end
end

FixtureRunner.run(SnailsCacheTest, [
  "test_fetch_misses_then_hits",
  "test_fetch_caches_a_nil_value",
  "test_empty_string_is_a_hit",
  "test_write_and_read",
  "test_exist_and_delete",
  "test_increment_counts",
  "test_delete_and_clear",
  "test_expired_entry_is_a_miss",
  "test_expires_in_must_be_positive",
  "test_accepts_duration_expiry",
  "test_expires_in_must_be_seconds_or_duration",
  "test_fetch_requires_a_block",
  "test_concurrent_increment"
])
