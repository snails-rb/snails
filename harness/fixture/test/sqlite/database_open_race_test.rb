require_relative "../test_helper"
require_relative "../harness_runner"
require_relative "../test_database"

# SQLite pool opening: every pool shard opens its own handles. All shards must
# read a valid handle even when their first requests arrive together — the
# process-wide open out-buffer is one static slot.
class DatabaseOpenRaceTest < TestBase
  def assert_equal(expected, actual)
    raise("expected #{expected.inspect}, got #{actual.inspect}") unless expected == actual
  end

  # Eight threads reach eight pool shards at once, so every shard opens its
  # first connection in the same window; the run must finish without a crash.
  def test_concurrent_first_use_opens_a_valid_handle_on_every_shard
    TestDatabase.configure!("sqlite_open_race", pool_size: 32)
    threads = []
    8.times do
      threads << Thread.new do
        Sqlx::Database.with_connection do
          Sqlx::Database.exec_read("SELECT 1 AS one", [])
        end
      end
    end
    threads.each { |thread| thread.join }
  ensure
    Sqlx::Database.close
    path = "/tmp/snails_sqlite_open_race.sqlite3"
    File.delete(path) if File.exist?(path)
  end
end

FixtureRunner.run(DatabaseOpenRaceTest, [ :test_concurrent_first_use_opens_a_valid_handle_on_every_shard ])
