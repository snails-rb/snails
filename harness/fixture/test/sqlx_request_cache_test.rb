require_relative "test_helper"
require_relative "harness_runner"
require_relative "test_database"

# The request-cache contract, shared by both backends. The same case file
# runs in the sqlite workspace (file database) and the pg workspace
# (scratch database from PG_URL), and both gates count the same SQL/CACHE
# trace markers — one contract, one engine, one set of cases. RH_SQL_TRACE
# makes each real execution print "SQL" and each replay "CACHE" to stderr.
TestDatabase.configure!("sqlx_request_cache")

class RequestCacheTest < TestBase
  def setup
    TestDatabase.drop_tables!("cache_items")
    TestDatabase.exec("CREATE TABLE cache_items (id INTEGER PRIMARY KEY, name TEXT NOT NULL)")
    Sqlx::Database.exec("INSERT INTO cache_items (id, name) VALUES (1, 'alpha'), (2, 'beta'), (3, 'gamma')")
  end

  def assert_equal(expected, actual, msg = nil)
    raise(msg || "expected #{expected.inspect}, got #{actual.inspect}") unless expected == actual
  end

  def count_marker(marker)
    rows = Sqlx::Base.rows_by_sql("SELECT COUNT(*) AS total FROM cache_items /* #{marker} */")
    rows[0]["total"].to_i
  end

  # The same read repeated in one lease executes once; both calls still
  # answer the same rows.
  def test_repeat_read_is_cached
    Sqlx::Database.with_connection do
      first = count_marker("cache_repeat")
      second = count_marker("cache_repeat")
      assert_equal 3, first
      assert_equal 3, second
    end
  end

  # DB time grows for one real statement and stays put on a query-cache
  # replay: a cache hit never reaches the adapter's statement entry.
  def test_db_time_accumulates_real_reads_and_skips_cache_hits
    Snails::Logger::Context.begin_request
    after_first = 0
    after_second = 0
    Sqlx::Database.with_connection do
      count_marker("db_timing")
      after_first = Snails::Logger::Context.db_us
      count_marker("db_timing")
      after_second = Snails::Logger::Context.db_us
    end
    assert_equal true, after_first > 0
    assert_equal after_first, after_second
  end

  # A failed statement still contributes its elapsed time; a request that
  # dies inside the adapter must not report zero for the failed query.
  def test_db_time_includes_a_failed_statement
    Snails::Logger::Context.begin_request
    raised = false
    begin
      Sqlx::Database.exec("THIS IS NOT SQL")
    rescue RuntimeError
      raised = true
    end
    assert_equal true, raised
    assert_equal true, Snails::Logger::Context.db_us > 0
  end

  # The cache key covers the bound values: id 2 is not a replay of id 1,
  # and repeating id 1 is a hit.
  def test_bound_reads_key_on_bind_values
    Sqlx::Database.with_connection do
      one = Sqlx::Base.rows_by_sql("SELECT name FROM cache_items /* cache_bind */ WHERE id = ?", [ 1 ])
      two = Sqlx::Base.rows_by_sql("SELECT name FROM cache_items /* cache_bind */ WHERE id = ?", [ 2 ])
      again = Sqlx::Base.rows_by_sql("SELECT name FROM cache_items /* cache_bind */ WHERE id = ?", [ 1 ])
      assert_equal "alpha", one[0]["name"]
      assert_equal "beta", two[0]["name"]
      assert_equal "alpha", again[0]["name"]
    end
  end

  # A write in the same lease invalidates the read cache: the count after
  # the INSERT is one higher than the cached count before it.
  def test_write_invalidates_request_cache
    Sqlx::Database.with_connection do
      before = count_marker("cache_write")
      Sqlx::Base.write("INSERT INTO cache_items (id, name) VALUES (?, ?)", [ 4, "delta" ])
      after = count_marker("cache_write")
      assert_equal before + 1, after
    end
  end

  # A write in another thread invalidates this lease's cache too: the
  # process-wide generation moves, so the second count re-executes.
  def test_other_thread_write_invalidates
    Sqlx::Database.with_connection do
      before = count_marker("cache_thread")
      writer = Thread.new do
        Sqlx::Base.write("INSERT INTO cache_items (id, name) VALUES (?, ?)", [ 5, "thread" ])
      end
      writer.join
      after = count_marker("cache_thread")
      assert_equal before + 1, after
    end
  end

  # Outside a with_connection lease there is no request cache: the same read
  # runs twice.
  def test_reads_outside_a_lease_are_not_cached
    first = count_marker("cache_outside")
    second = count_marker("cache_outside")
    assert_equal 3, first
    assert_equal 3, second
  end

  # A nested lease shares the outer lease's cache and does not end it on
  # exit: the read after the inner block is still a hit.
  def test_nested_lease_shares_the_cache
    Sqlx::Database.with_connection do
      first = count_marker("cache_nested")
      Sqlx::Database.with_connection do
        inner = count_marker("cache_nested")
        assert_equal 3, inner
      end
      again = count_marker("cache_nested")
      assert_equal 3, first
      assert_equal 3, again
    end
  end

  # A result larger than the row cap is not cached; both reads execute the
  # full scan.
  def test_large_result_is_not_cached
    i = 0
    while i < 20
      Sqlx::Base.write("INSERT INTO cache_items (id, name) VALUES (?, ?)", [ 100 + i, "row" ])
      i += 1
    end
    Sqlx::Database.with_connection do
      first = Sqlx::Base.rows_by_sql("SELECT id, name FROM cache_items /* cache_large */ ORDER BY id")
      second = Sqlx::Base.rows_by_sql("SELECT id, name FROM cache_items /* cache_large */ ORDER BY id")
      assert_equal 23, first.length
      assert_equal 23, second.length
    end
  end

  # Mutating a returned row cannot poison the cache: the replay hands every
  # caller its own copy.
  def test_mutating_a_returned_row_cannot_poison_the_cache
    Sqlx::Database.with_connection do
      first = Sqlx::Base.rows_by_sql("SELECT name FROM cache_items /* cache_mutate */ WHERE id = 1")
      first[0]["name"] = "mutated"
      second = Sqlx::Base.rows_by_sql("SELECT name FROM cache_items /* cache_mutate */ WHERE id = 1")
      assert_equal "alpha", second[0]["name"]
    end
  end
end

FixtureRunner.run(RequestCacheTest, [
  "test_repeat_read_is_cached",
  "test_db_time_accumulates_real_reads_and_skips_cache_hits",
  "test_db_time_includes_a_failed_statement",
  "test_bound_reads_key_on_bind_values",
  "test_write_invalidates_request_cache",
  "test_other_thread_write_invalidates",
  "test_reads_outside_a_lease_are_not_cached",
  "test_nested_lease_shares_the_cache",
  "test_large_result_is_not_cached",
  "test_mutating_a_returned_row_cannot_poison_the_cache"
])
