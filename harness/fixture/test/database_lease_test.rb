require_relative "test_helper"
require_relative "harness_runner"
require_relative "test_database"

# Sqlx::Database connection lease (core) — what a database access with no
# `with_connection` lease does once `require_leases!` is on. The pool
# leases one connection to one thread at a time, so a no-lease fallback to
# the pool's first connection can land on a connection another thread
# holds — joining its open transaction and racing its statement cache.
# Pinned here: a lease-required process refuses a lease-less access loudly
# instead, and the logger's batch hand-off (a queue INSERT from a thread
# holding no lease) stays legal because it leases its own connection.
#
# pool_size 1 keeps every lease on one connection, so the refusal needs no
# pool contention to be deterministic.
class DatabaseLeaseTest < TestBase
  # The transport stand-in for the hand-off case: its `deliver` writes one
  # row, so the case can tell "the hand-off leased a connection" (the write
  # succeeds while the lease requirement is on) from "it ran lease-less"
  # (refused).
  class HandOffWriteTransport
    def deliver(records)
      Sqlx::Base.write("INSERT INTO t (name) VALUES (?)", [ "hand-off" ])
    end
  end

  # The no-database counterpart: its `deliver` accepts the batch without a
  # query, the OTLP default's shape at this seam.
  class HandOffNoWriteTransport
    def deliver(records)
      nil
    end
  end

  def setup
    TestDatabase.configure!("database_lease", pool_size: 1)
    # The flag is one-way per process, so the second case's DDL also runs
    # under a lease — the helper's exec owns that boundary.
    TestDatabase.drop_tables!("t")
    TestDatabase.exec("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT NOT NULL)")
    Sqlx::Database.require_leases!
  end

  def assert_equal(expected, actual, msg = nil)
    raise(msg || "expected #{expected.inspect}, got #{actual.inspect}") unless expected == actual
  end

  def count_named(name)
    Sqlx::Database.with_connection do
      Sqlx::Base.rows_by_sql("SELECT COUNT(*) AS n FROM t WHERE name = ?", [name])[0]["n"].to_i
    end
  end

  # Thread A leases the only pooled connection and opens a transaction on
  # it; the main thread writes with no lease while that transaction is
  # open. Expected: the lease-less write is refused with an error naming
  # `with_connection` — it must not land on A's connection and vanish with
  # A's rollback.
  def test_a_lease_required_process_refuses_a_write_outside_any_lease
    started = [false]
    rolled_back = [""]
    thread = Thread.new do
      begin
        Sqlx::Database.with_connection do
          Sqlx::Base.transaction do
            Sqlx::Base.write("INSERT INTO t (name) VALUES (?)", [ "leased" ])
            started[0] = true
            sleep 0.3
            raise "rollback"
          end
        end
      rescue => e
        rolled_back[0] = e.message
      end
    end
    while !started[0]
      sleep 0.01
    end

    refused = [""]
    begin
      Sqlx::Base.write("INSERT INTO t (name) VALUES (?)", [ "out-of-lease" ])
    rescue => e
      refused[0] = e.message
    end
    thread.join

    assert_equal "rollback", rolled_back[0]
    assert_equal true, refused[0].include?("with_connection")
    assert_equal 0, count_named("leased")
    assert_equal 0, count_named("out-of-lease")
  end

  # The logger hands a batch off from a thread holding no lease (a request
  # thread writing its completed-request record). Expected: the hand-off
  # leases a connection for the transport call, so the transport's queue
  # write succeeds even though the caller holds no lease.
  def test_the_log_hand_off_leases_its_own_connection
    delivery = Snails::Logger::Delivery.new
    delivery.transport = HandOffWriteTransport.new
    record = Snails::Logger::Record.new(:info, "probe.hand_off", "probe")

    assert_equal nil, delivery.deliver(record)
    assert_equal nil, delivery.flush
    assert_equal 1, count_named("hand-off")
  end

  # A lease scope with no database access must not check out a connection.
  # One pool slot and a holder thread keep the case deterministic: an eager
  # checkout would wait for the holder, while the lazy scope returns at once.
  def test_a_no_database_scope_does_not_check_out_a_connection
    held = [false]
    holder = Thread.new do
      Sqlx::Database.with_connection do
        Sqlx::Base.rows_by_sql("SELECT 1 AS one", [])
        held[0] = true
        sleep 0.4
      end
    end
    i = 0
    while !held[0] && i < 200
      sleep 0.01
      i += 1
    end

    started = Time.now
    Sqlx::Database.with_connection do
    end
    elapsed = Time.now - started
    holder.join

    assert_equal true, elapsed < 0.2
  end

  # A log hand-off whose transport does no database work must not check out a
  # connection. The no-op transport has the OTLP default's shape at the
  # delivery seam: it accepts the batch without a query.
  def test_a_log_hand_off_without_database_work_does_not_check_out_a_connection
    held = [false]
    holder = Thread.new do
      Sqlx::Database.with_connection do
        Sqlx::Base.rows_by_sql("SELECT 1 AS one", [])
        held[0] = true
        sleep 0.4
      end
    end
    i = 0
    while !held[0] && i < 200
      sleep 0.01
      i += 1
    end

    delivery = Snails::Logger::Delivery.new
    delivery.transport = HandOffNoWriteTransport.new
    record = Snails::Logger::Record.new(:info, "probe.no_db_hand_off", "probe")

    started = Time.now
    assert_equal nil, delivery.deliver(record)
    assert_equal nil, delivery.flush
    elapsed = Time.now - started
    holder.join

    assert_equal true, elapsed < 0.2
  end
end

FixtureRunner.run(DatabaseLeaseTest, [
  :test_a_lease_required_process_refuses_a_write_outside_any_lease,
  :test_the_log_hand_off_leases_its_own_connection,
  :test_a_no_database_scope_does_not_check_out_a_connection,
  :test_a_log_hand_off_without_database_work_does_not_check_out_a_connection
])
