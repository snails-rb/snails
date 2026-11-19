require_relative "test_helper"
require_relative "harness_runner"
require_relative "test_database"

# The database adapter's blocking boundary. A statement runs inside one
# native call with no safepoint, so a slow one — a page scan, an aggregate —
# holds its OS worker for the whole run. Declared `blocking: true`, the
# collector does not wait for that worker: other workers keep running. Without
# it, a collection raised during the statement parks every worker at the
# barrier with it, which is a whole-process freeze while the query runs.
#
# The case fails when a declaration loses the keyword, and that failure is the
# only visible trace of the bug: nothing else in the suite runs a statement
# long enough to overlap a collection.
class DatabaseBlockingTest < TestBase
  # The longest gap the ticker may see inside the statement's window. The
  # unguarded case measures ~0.8s here; the guarded one a few milliseconds.
  # The bound is wide enough for a loaded CI runner and narrow enough that a
  # whole-statement stall cannot pass.
  MAX_TICK_GAP_SECONDS = 0.25

  # The ticker's statement window target: long enough to collect several
  # times while the query runs, short enough to keep the test run quick.
  TARGET_STATEMENT_SECONDS = 0.8

  def setup
    # Three OS workers is main plus two helpers, so the ticker gets a worker
    # of its own while the statement runs on this one. One helper would hide
    # the defect: every thread shares that worker anyway.
    ENV["SPINEL_WORKERS"] = "3"
    # A low collection floor makes a collection certain inside the window.
    # Both values are read when the first Thread starts.
    ENV["SPINEL_GC_THRESHOLD_OBJ_KB"] = "16"
    TestDatabase.configure!("database_blocking")
  end

  def assert_equal(expected, actual, msg = nil)
    raise(msg || "expected #{expected.inspect}, got #{actual.inspect}") unless expected == actual
  end

  # Run the selected adapter's long statement while a ticker records the
  # largest gap between its own iterations. The statement is a real one, not
  # a synthetic C call: the declaration under test is the adapter's.
  def test_a_long_statement_keeps_other_threads_running
    statement = long_statement
    running = [ true ]
    max_gap = [ 0.0 ]
    last = [ Process.clock_gettime(Process::CLOCK_MONOTONIC) ]
    ticker = Thread.new do
      while running[0]
        # Allocate so the object heap crosses its floor during the window.
        _waste = "x" * 16_384
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        gap = now - last[0]
        max_gap[0] = gap if gap > max_gap[0]
        last[0] = now
        sleep 0.002
      end
    end

    # Let the ticker start on its own worker before the statement begins.
    sleep 0.05
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    Sqlx::Database.with_connection { run_statement(statement) }
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    running[0] = false
    ticker.join

    # A statement that finished early proves nothing: the case needs the
    # window to overlap collections.
    assert_equal true, elapsed >= MAX_TICK_GAP_SECONDS
    assert_equal true, max_gap[0] < MAX_TICK_GAP_SECONDS
  end

  # The statement and its bind values for the selected adapter. SQLite scans
  # rows, so its cost is calibrated to the target; pg waits on the server
  # with `pg_sleep`, which is the same shape — one call, no safepoint.
  def long_statement
    if TestDatabase.pg?
      [ "SELECT pg_sleep(?)", [ TARGET_STATEMENT_SECONDS ] ]
    else
      [ "WITH RECURSIVE c(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM c WHERE i < ?) SELECT count(*) AS n FROM c",
        [ sqlite_rows_for_target ] ]
    end
  end

  # Rows whose recursive scan costs about `TARGET_STATEMENT_SECONDS` on this
  # machine. A fixed count would either finish too fast to overlap a
  # collection or make a slow test run much slower.
  def sqlite_rows_for_target
    probe_rows = 200_000
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    run_statement([ "WITH RECURSIVE c(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM c WHERE i < ?) SELECT count(*) AS n FROM c",
                    [ probe_rows ] ])
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    rows = (TARGET_STATEMENT_SECONDS * probe_rows / elapsed).to_i
    rows = probe_rows if rows < probe_rows
    rows = 20_000_000 if rows > 20_000_000
    rows
  end

  def run_statement(statement)
    Sqlx::Base.rows_by_sql(statement[0], statement[1])
  end
end

FixtureRunner.run(DatabaseBlockingTest, [
  "test_a_long_statement_keeps_other_threads_running"
])
