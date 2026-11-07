require_relative "../test_helper"
require_relative "../harness_runner"

# The connection-failure contract: a statement on a dead session raises
# `Sqlx::ConnectionFailed`, the pool drops that connection, and a later checkout
# opens a fresh one. Only the failed connection is dropped; another lease keeps
# its session. A normal SQL error is not a connection failure.
Sqlx::Database.configure(ENV["PG_URL"].to_s, pool_size: 2)

class PgReconnectTest < TestBase
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

  def raw_connect
    conn = Sqlx::Database::Libpq.PQconnectdb(ENV["PG_URL"].to_s)
    if Sqlx::Database::Libpq.PQstatus(conn) != Sqlx::Database::Libpq::CONNECTION_OK
      message = Sqlx::Database::Libpq.PQerrorMessage(conn)
      Sqlx::Database::Libpq.PQfinish(conn)
      raise "raw pg connect failed: " + message
    end
    conn
  end

  def raw_exec_bool(conn, sql)
    res = Sqlx::Database::Libpq.PQexec(conn, sql)
    if Sqlx::Database::Libpq.PQresultStatus(res) != Sqlx::Database::Libpq::PGRES_TUPLES_OK
      message = Sqlx::Database::Libpq.PQresultErrorMessage(res)
      Sqlx::Database::Libpq.PQclear(res)
      raise "raw pg query failed: " + message
    end
    answer = Sqlx::Database::Libpq.PQntuples(res) == 1 &&
             Sqlx::Database::Libpq.PQgetvalue(res, 0, 0) == "t"
    Sqlx::Database::Libpq.PQclear(res)
    answer
  end

  def raw_backend_alive?(conn, pid)
    res = Sqlx::Database::Libpq.PQexec(conn, "SELECT 1 FROM pg_stat_activity WHERE pid = " + pid.to_s)
    if Sqlx::Database::Libpq.PQresultStatus(res) != Sqlx::Database::Libpq::PGRES_TUPLES_OK
      message = Sqlx::Database::Libpq.PQresultErrorMessage(res)
      Sqlx::Database::Libpq.PQclear(res)
      raise "pg_stat_activity failed: " + message
    end
    alive = Sqlx::Database::Libpq.PQntuples(res) > 0
    Sqlx::Database::Libpq.PQclear(res)
    alive
  end

  # Kill a backend from another libpq connection and wait until the server has
  # dropped it. `pg_terminate_backend` only signals, so the next statement is
  # not guaranteed to see a closed socket yet.
  def terminate_backend(killer, pid)
    assert_equal true, raw_exec_bool(killer, "SELECT pg_terminate_backend(" + pid.to_s + ")")
    i = 0
    while raw_backend_alive?(killer, pid) && i < 200
      sleep 0.01
      i += 1
    end
    assert_equal false, raw_backend_alive?(killer, pid)
  end

  # Kill this lease's backend. Expected: the next statement raises
  # ConnectionFailed, the closed connection refuses `changes` and
  # `last_insert_rowid`, and a later checkout gets a new backend pid.
  def test_a_failed_connection_is_discarded_and_the_next_checkout_reconnects
    killer = raw_connect
    victim = [0]
    failed = [nil]
    second = [nil]
    changes_failed = [nil]
    rowid_failed = [nil]
    begin
      Sqlx::Database.with_connection do
        victim[0] = backend_pid
        terminate_backend(killer, victim[0])
        begin
          Sqlx::Base.rows_by_sql("SELECT 1 AS one", [])
        rescue => e
          failed[0] = e
        end
        begin
          Sqlx::Database.changes
        rescue => e
          changes_failed[0] = e
        end
        begin
          Sqlx::Database.last_insert_rowid
        rescue => e
          rowid_failed[0] = e
        end
        begin
          Sqlx::Base.rows_by_sql("SELECT 1 AS one", [])
        rescue => e
          second[0] = e
        end
      end
      assert_equal "Sqlx::ConnectionFailed", failed[0].class.to_s
      assert_equal "Sqlx::ConnectionFailed", changes_failed[0].class.to_s
      assert_equal "Sqlx::ConnectionFailed", rowid_failed[0].class.to_s
      assert_equal "Sqlx::ConnectionFailed", second[0].class.to_s
      next_pid = [0]
      Sqlx::Database.with_connection do
        next_pid[0] = backend_pid
      end
      assert_equal false, next_pid[0] == victim[0]
    ensure
      Sqlx::Database::Libpq.PQfinish(killer)
    end
  end

  # Two leases hold two sessions. Expected: killing one lease's backend fails
  # only that lease; the other lease still answers on its own backend, and the
  # next checkout for the failed position opens a replacement.
  def test_a_failed_connection_does_not_disrupt_another_lease
    killer = raw_connect
    other_pid = [0]
    other_ready = [false]
    killed = [false]
    other_done = [false]
    other_ok = [false]
    other_error = [nil]
    other = Thread.new do
      begin
        Sqlx::Database.with_connection do
          other_pid[0] = backend_pid
          other_ready[0] = true
          wait_for(killed)
          Sqlx::Base.rows_by_sql("SELECT 1 AS one", [])
          other_ok[0] = true
          wait_for(other_done)
        end
      rescue => e
        other_error[0] = e
      end
    end
    begin
      wait_for(other_ready)
      victim = [0]
      failed = [nil]
      Sqlx::Database.with_connection do
        victim[0] = backend_pid
        terminate_backend(killer, victim[0])
        begin
          Sqlx::Base.rows_by_sql("SELECT 1 AS one", [])
        rescue => e
          failed[0] = e
        end
        killed[0] = true
      end
      next_pid = [0]
      Sqlx::Database.with_connection do
        next_pid[0] = backend_pid
      end
      other_done[0] = true
      other.join
      assert_equal "Sqlx::ConnectionFailed", failed[0].class.to_s
      assert_equal true, other_error[0].nil?
      assert_equal true, other_ok[0]
      assert_equal false, other_pid[0] == victim[0]
      assert_equal false, next_pid[0] == victim[0]
    ensure
      other_done[0] = true
      Sqlx::Database::Libpq.PQfinish(killer)
    end
  end

  # A failed reconnect is the same public error as a lost session, so one unit
  # retry policy covers both. The pool opens lazily, so no server is needed to
  # exercise the open failure.
  def test_a_failed_reconnect_raises_connection_failed
    pool = Sqlx::Database::PgPool.new(
      "postgres://postgres:postgres@127.0.0.1:1/postgres?connect_timeout=1",
      1
    )
    raised = [nil]
    begin
      pool.checkout
    rescue => e
      raised[0] = e
    end
    assert_equal "Sqlx::ConnectionFailed", raised[0].class.to_s
    assert_equal true, raised[0].message.include?("PG connect failed")
  end

  # A transaction that loses its session has nothing left to roll back.
  # Expected: the block's own failure survives the rollback attempt — the
  # closed connection must not replace it with a second ConnectionFailed.
  def test_a_failed_connection_keeps_the_original_transaction_error
    killer = raw_connect
    raised = [nil]
    begin
      Sqlx::Database.with_connection do
        pid = backend_pid
        Sqlx::Base.transaction do
          terminate_backend(killer, pid)
          begin
            Sqlx::Base.rows_by_sql("SELECT 1 AS one", [])
          rescue Sqlx::ConnectionFailed
            # The session is gone; the block continues to its own failure.
          end
          raise "app-error"
        end
      end
    rescue => e
      raised[0] = e
    ensure
      Sqlx::Database::Libpq.PQfinish(killer)
    end
    assert_equal "RuntimeError", raised[0].class.to_s
    assert_equal "app-error", raised[0].message
  end

  # The pre-lease fallback answers position 0 without a lease. Expected: a
  # failed fallback connection is repaired on the next fallback call, and the
  # replacement is a new backend. This covers the repair path that opens
  # outside the pool lock.
  def test_the_fallback_repairs_a_failed_connection
    killer = raw_connect
    victim = [0]
    failed = [nil]
    next_pid = [0]
    begin
      victim[0] = Sqlx::Base.rows_by_sql("SELECT pg_backend_pid() AS pid", [])[0]["pid"].to_i
      terminate_backend(killer, victim[0])
      begin
        Sqlx::Base.rows_by_sql("SELECT 1 AS one", [])
      rescue => e
        failed[0] = e
      end
      next_pid[0] = Sqlx::Base.rows_by_sql("SELECT pg_backend_pid() AS pid", [])[0]["pid"].to_i
    ensure
      Sqlx::Database::Libpq.PQfinish(killer)
    end
    assert_equal "Sqlx::ConnectionFailed", failed[0].class.to_s
    assert_equal false, next_pid[0] == victim[0]
  end

  # A normal SQL error is not a connection failure: the pool keeps the
  # connection, so the next statement runs on the same backend.
  def test_an_ordinary_sql_error_keeps_the_connection
    raised = [nil]
    before_pid = [0]
    after_pid = [0]
    Sqlx::Database.with_connection do
      before_pid[0] = backend_pid
      begin
        Sqlx::Base.rows_by_sql("SELECT * FROM no_such_table_for_reconnect", [])
      rescue => e
        raised[0] = e
      end
      after_pid[0] = backend_pid
    end
    assert_equal false, raised[0].nil?
    assert_equal false, raised[0].is_a?(Sqlx::ConnectionFailed)
    assert_equal before_pid[0], after_pid[0]
  end

  # A free connection can die while it waits in the pool. Expected: the next
  # checkout pings it, discards it, opens a replacement, and runs the block
  # successfully — the request never sees the dead connection.
  def test_checkout_ping_replaces_a_stale_free_connection
    Sqlx::Database.configure(ENV["PG_URL"].to_s, pool_size: 1)
    killer = raw_connect
    victim = [0]
    next_pid = [0]
    begin
      Sqlx::Database.with_connection do
        victim[0] = backend_pid
      end
      terminate_backend(killer, victim[0])
      Sqlx::Database.with_connection do
        next_pid[0] = backend_pid
        Sqlx::Base.rows_by_sql("SELECT 1 AS one", [])
      end
    ensure
      Sqlx::Database::Libpq.PQfinish(killer)
      Sqlx::Database.configure(ENV["PG_URL"].to_s, pool_size: 2)
    end
    assert_equal false, next_pid[0] == victim[0]
  end

  # A connection idle past the idle bound is replaced at checkout, not handed
  # back to the request. Expected: the next checkout opens a new backend.
  def test_idle_timeout_replaces_a_long_idle_connection
    ENV["DATABASE_IDLE_TIMEOUT_MS"] = "100"
    Sqlx::Database.configure(ENV["PG_URL"].to_s, pool_size: 1)
    old_pid = [0]
    new_pid = [0]
    begin
      Sqlx::Database.with_connection do
        old_pid[0] = backend_pid
      end
      sleep 0.15
      Sqlx::Database.with_connection do
        new_pid[0] = backend_pid
      end
    ensure
      ENV.delete("DATABASE_IDLE_TIMEOUT_MS")
      Sqlx::Database.configure(ENV["PG_URL"].to_s, pool_size: 2)
    end
    assert_equal false, new_pid[0] == old_pid[0]
  end

  # A connection older than the lifetime bound is replaced at checkout even
  # when it was used recently. Expected: the next checkout opens a new backend.
  def test_max_lifetime_replaces_an_old_connection
    ENV["DATABASE_MAX_LIFETIME_MS"] = "100"
    Sqlx::Database.configure(ENV["PG_URL"].to_s, pool_size: 1)
    old_pid = [0]
    new_pid = [0]
    begin
      Sqlx::Database.with_connection do
        old_pid[0] = backend_pid
      end
      sleep 0.15
      Sqlx::Database.with_connection do
        new_pid[0] = backend_pid
      end
    ensure
      ENV.delete("DATABASE_MAX_LIFETIME_MS")
      Sqlx::Database.configure(ENV["PG_URL"].to_s, pool_size: 2)
    end
    assert_equal false, new_pid[0] == old_pid[0]
  end

  # The pool's lease step and the connection's time getters are internal.
  # Expected: calling them from outside raises NoMethodError; the public
  # checkout entry still works.
  def test_the_pool_internal_steps_are_private
    pool = Sqlx::Database::PgPool.new(ENV["PG_URL"].to_s, 1)
    token = pool.checkout
    conn = token.connection
    age_error = nil
    begin
      conn.age_seconds(0.0)
    rescue NoMethodError => e
      age_error = e
    end
    lease_error = nil
    begin
      pool.lease
    rescue NoMethodError => e
      lease_error = e
    end
    token.release(conn, true)
    pool.close_all
    assert_equal "NoMethodError", age_error.class.to_s
    assert_equal "NoMethodError", lease_error.class.to_s
  end
end

FixtureRunner.run(PgReconnectTest, [
  "test_a_failed_connection_is_discarded_and_the_next_checkout_reconnects",
  "test_a_failed_connection_does_not_disrupt_another_lease",
  "test_a_failed_reconnect_raises_connection_failed",
  "test_a_failed_connection_keeps_the_original_transaction_error",
  "test_the_fallback_repairs_a_failed_connection",
  "test_an_ordinary_sql_error_keeps_the_connection",
  "test_checkout_ping_replaces_a_stale_free_connection",
  "test_idle_timeout_replaces_a_long_idle_connection",
  "test_max_lifetime_replaces_an_old_connection",
  "test_the_pool_internal_steps_are_private"
])
