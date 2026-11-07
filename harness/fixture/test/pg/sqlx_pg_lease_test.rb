require_relative "../test_helper"
require_relative "../harness_runner"

# The PostgreSQL half of the connection-lifetime contract: a lease owns one
# connection, so two requests never share a session, a transaction cannot join
# another lease's work, `lastval()`/`changes` answer on the lease's connection,
# and the pool refuses a lease-less access once the server requires leases.
# SQLite's gate covers the same cases through its own pool; this file runs in
# the pg gate only.
Sqlx::Database.configure(ENV["PG_URL"].to_s, pool_size: 2)

class PgLeaseItem < Sqlx::Base
  %w[id name].each do |column|
    define_method(column) { read_attribute(column) }
  end

  def self.table_name = "lease_items"
  def self.only_columns = [:id, :name]
end

class PgLeaseTest < TestBase
  def setup
    Sqlx::Database.exec("DROP TABLE IF EXISTS lease_items")
    Sqlx::Database.exec("CREATE TABLE lease_items (id BIGSERIAL PRIMARY KEY, name TEXT NOT NULL)")
  end

  def assert_equal(expected, actual, msg = nil)
    raise(msg || "expected #{expected.inspect}, got #{actual.inspect}") unless expected == actual
  end

  def backend_pid
    Sqlx::Base.rows_by_sql("SELECT pg_backend_pid() AS pid", [])[0]["pid"].to_i
  end

  def wait_for(flag)
    i = 0
    while !flag[0] && i < 200
      sleep 0.01
      i += 1
    end
  end

  def count_named(name)
    Sqlx::Base.rows_by_sql("SELECT COUNT(*) AS n FROM lease_items WHERE name = ?", [ name ])[0]["n"].to_i
  end

  # Two threads hold a lease at the same time. Expected: each block runs on a
  # different libpq connection (different backend pid) — the pool gives each
  # lease its own session instead of serializing both through one.
  def test_two_leases_get_distinct_connections
    ready_one = [false]
    ready_two = [false]
    pids = []
    lock = Mutex.new

    one = Thread.new do
      Sqlx::Database.with_connection do
        pid = backend_pid
        lock.synchronize { pids.push(pid) }
        ready_one[0] = true
        wait_for(ready_two)
      end
    end
    two = Thread.new do
      Sqlx::Database.with_connection do
        pid = backend_pid
        lock.synchronize { pids.push(pid) }
        ready_two[0] = true
        wait_for(ready_one)
      end
    end
    one.join
    two.join

    assert_equal 2, pids.length
    assert_equal false, pids[0] == pids[1]
  end

  # Thread A opens a transaction and inserts; thread B inserts on its own
  # lease before A rolls back. Expected: A's rollback removes only A's row —
  # B's write never joined A's transaction.
  def test_transaction_rollback_does_not_erase_another_lease
    started = [false]
    finished = [false]
    failure = [""]

    writer = Thread.new do
      begin
        Sqlx::Database.with_connection do
          Sqlx::Base.transaction do
            Sqlx::Base.write("INSERT INTO lease_items (name) VALUES (?)", [ "rolled-back" ])
            started[0] = true
            wait_for(finished)
            raise "rollback"
          end
        end
      rescue => e
        failure[0] = e.message
      end
    end

    wait_for(started)
    Sqlx::Database.with_connection do
      # A's write is uncommitted on another connection: B must not see it.
      assert_equal 0, count_named("rolled-back")
      Sqlx::Base.write("INSERT INTO lease_items (name) VALUES (?)", [ "kept" ])
    end
    finished[0] = true
    writer.join

    assert_equal "rollback", failure[0]
    assert_equal 0, count_named("rolled-back")
    assert_equal 1, count_named("kept")
  end

  # Two concurrent create! loops. Expected: every call hands back the row it
  # inserted (the name matches its own prefix), never the other thread's row.
  def test_create_returns_its_own_row_under_concurrency
    results = []
    lock = Mutex.new
    one = Thread.new do
      Sqlx::Database.with_connection do
        i = 0
        while i < 25
          rec = PgLeaseItem.create!({ name: "one-" + i.to_s })
          lock.synchronize { results.push(rec.name) }
          i += 1
        end
      end
    end
    two = Thread.new do
      Sqlx::Database.with_connection do
        i = 0
        while i < 25
          rec = PgLeaseItem.create!({ name: "two-" + i.to_s })
          lock.synchronize { results.push(rec.name) }
          i += 1
        end
      end
    end
    one.join
    two.join

    assert_equal 50, results.length
    results.each do |name|
      assert_equal true, name.start_with?("one-") || name.start_with?("two-")
    end
    assert_equal 50, Sqlx::Base.rows_by_sql("SELECT COUNT(*) AS n FROM lease_items", [])[0]["n"].to_i
  end

  # `changes` belongs to the lease's connection. Expected: A updates one row,
  # B updates two on its own lease, and A still reads 1 after B's write.
  def test_changes_are_connection_scoped
    Sqlx::Database.exec("INSERT INTO lease_items (name) VALUES ('a'), ('b')")
    a_wrote = [false]
    b_wrote = [false]
    a_changes = [0]
    b_changes = [0]

    one = Thread.new do
      Sqlx::Database.with_connection do
        Sqlx::Database.exec_write("UPDATE lease_items SET name = name WHERE name = ?", [ "a" ])
        a_wrote[0] = true
        wait_for(b_wrote)
        a_changes[0] = Sqlx::Database.changes
      end
    end
    two = Thread.new do
      wait_for(a_wrote)
      Sqlx::Database.with_connection do
        Sqlx::Database.exec_write("UPDATE lease_items SET name = name", [])
        b_wrote[0] = true
        b_changes[0] = Sqlx::Database.changes
      end
    end
    one.join
    two.join

    assert_equal 1, a_changes[0]
    assert_equal 2, b_changes[0]
  end

  # Once the server requires leases, a database access outside one is refused
  # with a message naming `with_connection` — it must not land on a pooled
  # connection another thread holds.
  def test_require_leases_refuses_a_lease_less_access
    Sqlx::Database.require_leases!
    refused = [""]
    begin
      Sqlx::Base.rows_by_sql("SELECT 1 AS one", [])
    rescue => e
      refused[0] = e.message
    end
    assert_equal true, refused[0].include?("with_connection")
  end
end

FixtureRunner.run(PgLeaseTest, [
  "test_two_leases_get_distinct_connections",
  "test_transaction_rollback_does_not_erase_another_lease",
  "test_create_returns_its_own_row_under_concurrency",
  "test_changes_are_connection_scoped",
  "test_require_leases_refuses_a_lease_less_access"
])
