require_relative "../test_helper"
require_relative "../harness_runner"

# Sqlx busy handler (core, sqlite) — SQLite admits one writer per file, and a
# writer that cannot take the lock waits in the adapter's busy handler. The
# default handler behind `PRAGMA busy_timeout` sleeps on a back-off ladder, so
# under a stream of short writes a waiter can sleep through every gap and time
# out while the database commits steadily. The adapter installs a fair handler
# instead: retry every millisecond, give up when the wall-clock budget is
# spent. The cases here pin the wait, the budget, the typed `Sqlx::Busy` a
# spent budget raises, and a log hand-off inside a write transaction.
class SqliteWriteFairnessTest < TestBase
  WRITERS = 4
  PER_WRITER = 5

  # A transport that answers with a queue-style INSERT, like the default log
  # transport — the shape that makes a hand-off wait on the database.
  class DatabaseWritingTransport
    def deliver(records)
      Sqlx::Base.write("INSERT INTO t (name) VALUES (?)", [ "log" ])
    end
  end

  # Local lines are captured, so the logging case does not write to stderr.
  class LineOutput
    def initialize
      @lines = []
    end

    def lines
      @lines
    end

    def write(line)
      @lines << line
    end

    def flush
    end
  end

  def setup
    configure_with_budget(2000)
  end

  # Each case gets its own file and budget: the budget is what a wait costs
  # before `Sqlx::Busy`, so the mapping case needs a short one.
  def configure_with_budget(budget_ms)
    path = "/tmp/snails_sqlite_busy_handler.sqlite3"
    # Close the previous pool before removing its file. macOS SQLite answers
    # SQLITE_IOERR (10) when a new table operation reaches a connection whose
    # file was removed underneath it.
    Sqlx::Database.close
    File.delete(path) if File.exist?(path)
    Sqlx::Database.configure(path, pool_size: 4, busy_timeout_ms: budget_ms)
    Sqlx::Database.exec("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT NOT NULL)")
  end

  def assert_equal(expected, actual, msg = nil)
    raise(msg || "expected #{expected.inspect}, got #{actual.inspect}") unless expected == actual
  end

  def count_rows
    Sqlx::Base.rows_by_sql("SELECT COUNT(*) AS n FROM t")[0]["n"].to_i
  end

  # Writes from `name` on a leased connection: any failure is collected on the
  # shared error list instead of ending the thread.
  def write_many(name, errors, errors_lock)
    Sqlx::Database.with_connection do
      i = 0
      while i < PER_WRITER
        begin
          Sqlx::Base.write("INSERT INTO t (name) VALUES (?)", [ name ])
        rescue => e
          errors_lock.synchronize { errors.push(e.class.to_s + ": " + e.message) }
        end
        i += 1
      end
    end
  end

  # Other writers write while one transaction holds the write lock for 0.5
  # seconds. Expectation: waiting stays within the budget, every write commits,
  # and BUSY never occurs.
  def test_writers_wait_out_a_slow_transaction
    errors = []
    errors_lock = Mutex.new
    ready = [ false ]
    ready_lock = Mutex.new
    holder = Thread.new do
      Sqlx::Database.with_connection do
        Sqlx::Base.transaction do
          Sqlx::Base.write("INSERT INTO t (name) VALUES (?)", [ "holder" ])
          ready_lock.synchronize { ready[0] = true }
          sleep 0.5
        end
      end
    end
    waiting = true
    while waiting
      waiting = !ready_lock.synchronize { ready[0] }
      sleep 0.01 if waiting
    end

    writers = []
    i = 0
    while i < WRITERS
      writers.push(Thread.new("w" + i.to_s) { |name| write_many(name, errors, errors_lock) })
      i += 1
    end
    writers.each { |thread| thread.join }
    holder.join

    assert_equal "", errors.join(" | ")
    assert_equal 1 + WRITERS * PER_WRITER, count_rows
  end

  # When another connection holds the file write lock and the budget (100ms)
  # passes, expect: the wait is cut off at the budget and becomes `Sqlx::Busy`,
  # and the next transaction starts on the same connection after the lock is
  # released.
  def test_a_wait_past_the_budget_raises_sqlx_busy
    configure_with_budget(100)
    ready = [ false ]
    ready_lock = Mutex.new
    holder = Thread.new do
      Sqlx::Database.with_connection do
        Sqlx::Database.exec("BEGIN IMMEDIATE")
        Sqlx::Base.write("INSERT INTO t (name) VALUES (?)", [ "foreign" ])
        ready_lock.synchronize { ready[0] = true }
        sleep 0.5
        Sqlx::Database.exec("ROLLBACK")
      end
    end
    waiting = true
    while waiting
      waiting = !ready_lock.synchronize { ready[0] }
      sleep 0.01 if waiting
    end

    raised = nil
    began = Time.now
    Sqlx::Database.with_connection do
      begin
        Sqlx::Base.write("INSERT INTO t (name) VALUES (?)", [ "waiter" ])
      rescue => e
        raised = e
      end
    end
    elapsed = Time.now - began
    holder.join

    assert_equal "Sqlx::Busy", raised.class.to_s
    assert_equal true, elapsed < 0.45
    Sqlx::Base.transaction { Sqlx::Base.write("INSERT INTO t (name) VALUES (?)", [ "after" ]) }
    assert_equal 1, count_rows
  end

  # Even when a log batch hand-off happens inside a write transaction (queue
  # INSERT), it is handled on the same lease. Expectation: the hand-off joins
  # the transaction, commits with it, and the local line is also kept.
  def test_logging_inside_a_write_transaction_commits_with_it
    Snails.logger.transport = nil
    Snails.logger.flush
    out = LineOutput.new
    Snails.logger.output = out
    Snails.logger.transport = DatabaseWritingTransport.new

    i = 0
    while i < Snails::Logger::Delivery::MAX_RECORDS - 1
      Snails.logger.info("filler")
      i += 1
    end
    before = out.lines.length

    Sqlx::Database.with_connection do
      Sqlx::Base.transaction do
        Sqlx::Base.write("INSERT INTO t (name) VALUES (?)", [ "tx" ])
        Snails.logger.info("inside")
      end
    end

    assert_equal 2, count_rows
    assert_equal 1, out.lines.length - before
  end
end

FixtureRunner.run(SqliteWriteFairnessTest, [
  "test_writers_wait_out_a_slow_transaction",
  "test_a_wait_past_the_budget_raises_sqlx_busy",
  "test_logging_inside_a_write_transaction_commits_with_it"
])
