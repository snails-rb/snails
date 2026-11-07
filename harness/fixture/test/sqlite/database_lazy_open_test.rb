require_relative "../test_helper"
require_relative "../harness_runner"

# SQLite pool lifetime: configure builds the shards but opens no connection,
# so a prefork parent that only configures hands no live handle to its
# children. A child forked after configure opens its own pool on first use.
class DatabaseLazyOpenTest < TestBase
  def assert_equal(expected, actual)
    raise("expected #{expected.inspect}, got #{actual.inspect}") unless expected == actual
  end

  # configure does not create the database file; the first query does.
  def test_configure_does_not_open_a_connection_until_first_use
    path = "/tmp/snails_lazy_open.sqlite3"
    Sqlx::Database.close
    File.delete(path) if File.exist?(path)

    Sqlx::Database.configure(path, pool_size: 2)
    assert_equal false, File.exist?(path)

    Sqlx::Database.exec("CREATE TABLE t (id INTEGER PRIMARY KEY)")
    assert_equal true, File.exist?(path)

    Sqlx::Database.close
    File.delete(path) if File.exist?(path)
  end

  # The parent only configures; the child creates the schema and writes. The
  # parent then reads the row through its own lazily opened pool. This is the
  # prefork contract: no connection exists before the fork.
  def test_a_forked_child_opens_its_own_pool
    path = "/tmp/snails_fork_lazy.sqlite3"
    Sqlx::Database.close
    File.delete(path) if File.exist?(path)

    Sqlx::Database.configure(path, pool_size: 2)
    pid = Tep::Sock.sphttp_fork
    if pid == 0
      begin
        Sqlx::Database.exec("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT NOT NULL)")
        Sqlx::Base.write("INSERT INTO t (name) VALUES (?)", [ "child" ])
        Tep::Sock.sphttp_exit(0)
      rescue
        Tep::Sock.sphttp_exit(1)
      end
    end
    gone = Tep::Sock.sphttp_wait_any

    rows = Sqlx::Database.exec_read("SELECT name FROM t ORDER BY name", [])
    integrity = Sqlx::Database.exec_read("PRAGMA integrity_check", [])

    assert_equal pid, gone
    assert_equal 1, rows.length
    assert_equal "child", rows[0]["name"]
    assert_equal "ok", integrity[0]["integrity_check"]

    Sqlx::Database.close
    File.delete(path) if File.exist?(path)
  end
end

FixtureRunner.run(DatabaseLazyOpenTest, [
  "test_configure_does_not_open_a_connection_until_first_use",
  "test_a_forked_child_opens_its_own_pool"
])
