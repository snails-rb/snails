require_relative "test_helper"
require_relative "harness_runner"
require_relative "test_database"

# Sqlx::Base.transaction (core) — the block runs inside BEGIN/COMMIT and
# every failure rolls back before it leaves. These cases pin that the
# rollback covers the whole Exception tree, not just StandardError: an
# escaping ScriptError must not leave the transaction on a pooled
# connection (the next lease would run inside it, and a writer would hold
# the write lock until that lease ends).
class SqlxTransactionTest < TestBase
  def setup
    TestDatabase.configure!("sqlx_transaction", pool_size: 2)
    TestDatabase.drop_tables!("t")
    TestDatabase.exec("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT NOT NULL)")
  end

  def assert_equal(expected, actual, msg = nil)
    raise(msg || "expected #{expected.inspect}, got #{actual.inspect}") unless expected == actual
  end

  def count_rows
    Sqlx::Base.rows_by_sql("SELECT COUNT(*) AS n FROM t")[0]["n"].to_i
  end

  # A StandardError rolls the block back and comes back to the caller: the
  # INSERT inside the block is not committed.
  def test_a_standard_error_rolls_back_and_reraises
    raised = nil
    begin
      Sqlx::Database.with_connection do
        Sqlx::Base.transaction do
          Sqlx::Base.write("INSERT INTO t (name) VALUES (?)", [ "standard" ])
          raise "boom"
        end
      end
    rescue => e
      raised = e
    end
    assert_equal "boom", raised.message
    assert_equal 0, count_rows
  end

  # NotImplementedError is a ScriptError — outside StandardError. It must
  # roll back too, and the same connection must take the next transaction:
  # a transaction left open would make the next BEGIN fail.
  def test_a_script_error_rolls_back_and_leaves_the_connection_reusable
    raised = nil
    begin
      Sqlx::Database.with_connection do
        Sqlx::Base.transaction do
          Sqlx::Base.write("INSERT INTO t (name) VALUES (?)", [ "script" ])
          raise NotImplementedError, "boom"
        end
      end
    rescue NotImplementedError => e
      raised = e
    end
    assert_equal "boom", raised.message
    assert_equal 0, count_rows
    Sqlx::Database.with_connection do
      Sqlx::Base.transaction { Sqlx::Base.write("INSERT INTO t (name) VALUES (?)", [ "next" ]) }
    end
    assert_equal 1, count_rows
  end

  # Interrupt is a SignalException — outside StandardError and fatal to
  # the loop boundaries. The rollback must run before it reaches the
  # caller, the same as any other failure.
  def test_an_interrupt_rolls_back_and_reraises
    raised = nil
    begin
      Sqlx::Base.transaction do
        Sqlx::Base.write("INSERT INTO t (name) VALUES (?)", [ "interrupt" ])
        raise Interrupt, "stop"
      end
    rescue Interrupt => e
      raised = e
    end
    assert_equal "stop", raised.message
    assert_equal 0, count_rows
  end

  # While the failed transaction's lease is still open, a write on the
  # sibling connection succeeds and commits: the failure leaves no write
  # lock behind (a stale sqlite transaction would answer "database is
  # locked" after the busy timeout; a stale pg transaction would keep the
  # row lock).
  def test_a_failed_transaction_holds_no_lock_for_the_sibling_connection
    ready = [ false ]
    ready_lock = Mutex.new
    holder = Thread.new do
      Sqlx::Database.with_connection do
        begin
          Sqlx::Base.transaction do
            Sqlx::Base.write("INSERT INTO t (name) VALUES (?)", [ "held" ])
            raise NotImplementedError, "boom"
          end
        rescue NotImplementedError
        end
        ready_lock.synchronize { ready[0] = true }
        # Keep the lease open while the main thread writes, so the write
        # must take the sibling connection.
        sleep 0.5
      end
    end
    while true
      done = ready_lock.synchronize { ready[0] }
      break if done
      sleep 0.01
    end
    Sqlx::Database.with_connection do
      Sqlx::Base.write("INSERT INTO t (name) VALUES (?)", [ "sibling" ])
    end
    holder.join
    assert_equal 1, count_rows
  end
end

FixtureRunner.run(SqlxTransactionTest, [
  "test_a_standard_error_rolls_back_and_reraises",
  "test_a_script_error_rolls_back_and_leaves_the_connection_reusable",
  "test_an_interrupt_rolls_back_and_reraises",
  "test_a_failed_transaction_holds_no_lock_for_the_sibling_connection"
])
