# DB queue throughput bench — measurements only, no assertions. A
# measuring tool, not a gate: timings must never become assertions (a
# slow machine would turn the gate red). scripts/bench-queue.sh
# compiles its own entry around this file — it lives under bench/ so
# the snapshot suite (test/**/*_test.rb) never picks it up — and the
# numbers are recorded with their run date.
#
# Default run: every job body is a no-op, so the numbers are LOOP
# CEILINGS — the queue's own overhead, not the throughput of real work.
# Set BENCH_JOB_SLEEP_MS to give each body an I/O-shaped wait (a
# provider call proxy), BENCH_ROWS for the slow-profile row count, and
# BENCH_CONCURRENCY for a direct-drain concurrency spike. The spike runs
# DatabaseQueue.drain on N threads; it is the adapter's own parallel
# ceiling, independent of the worker loop.
#
# Three speeds are measured separately because they are limited by
# different things:
#   1. registering work — enqueue, as a request handler pays it;
#   2. worker-loop drain — drain through `drain_due?` with the real
#                          50ms poll (what a server process pays);
#   3. direct drain      — drain calls with nothing throttling, the
#                          same adapter's own ceiling.
#
# BENCH_LAUNCHER=1 runs the production path instead: this file calls
# `ActiveJob::Launcher.start` with the `WORKER_CONCURRENCY` the script
# sets, enqueues at BENCH_ARRIVAL_PER_MINUTE (default 1000) for
# BENCH_DURATION_SECONDS (default 60), waits for the backlog to clear,
# and reports throughput, p50/p95, and status counts. The body waits
# BENCH_JOB_SLEEP_MS (default 300 in this mode). SQLite lock-wait
# counters are not reported: the framework has no observability
# surface for them yet.
require_relative "../boot"

path = "/tmp/snails_queue_bench.sqlite3"
launcher_mode = (ENV["BENCH_LAUNCHER"] || "") == "1"
File.delete(path) if File.exist?(path)
File.delete(path + "-wal") if File.exist?(path + "-wal")
File.delete(path + "-shm") if File.exist?(path + "-shm")
if launcher_mode
  # Worker threads hold their leases while a job runs; the main thread
  # needs one more for the arrival stream and the backlog reads.
  Sqlx::Database.configure(path, pool_size: 16)
else
  Sqlx::Database.configure(path)
end
Sqlx::Database.exec(File.read("scaffold/queue/create_snails_queue.sql"))

# The bench prints numbers, not one line per job. The logger still
# formats each record, so its cost stays in the measurement; only the
# output is discarded.
class BenchLogOutput
  def write(line)
  end

  def flush
  end
end
Snails.logger.output = BenchLogOutput.new

class QueueBenchJob < ActiveJob::Base
  MODE_DEFAULT_SLEEP_MS = (ENV["BENCH_LAUNCHER"] || "") == "1" ? "300" : "0"
  SLEEP_MS = (ENV["BENCH_JOB_SLEEP_MS"] || MODE_DEFAULT_SLEEP_MS).to_i

  def self.perform(data)
    sleep(SLEEP_MS / 1000.0) if SLEEP_MS > 0
  end
end

class QueueBench
  # Enqueues that hit the busy timeout during the launcher run.
  ENQUEUE_BUSY = [0]

  def self.enqueue_rows(n)
    started = Time.now
    n.times { |i| ActiveJob::DatabaseQueue.enqueue("QueueBenchJob", -> { nil }, { "i" => i }) }
    Time.now - started
  end

  def self.clear_queue
    Sqlx::Database.exec("DELETE FROM snails_queue_jobs")
  end

  def self.drain_via_worker_loop(n)
    ran = 0
    started = Time.now
    while ran < n
      if ActiveJob::DatabaseQueue.drain_due?
        ran += Sqlx::Database.with_connection { ActiveJob::DatabaseQueue.drain }
      end
      sleep(0.05)
    end
    Time.now - started
  end

  def self.drain_directly(n)
    ran = 0
    started = Time.now
    while ran < n
      delta = Sqlx::Database.with_connection { ActiveJob::DatabaseQueue.drain }
      break if delta == 0

      ran += delta
    end
    Time.now - started
  end

  # N independent worker threads against the same queue. The adapters claim
  # rows atomically, so the total is the rows they consumed between them; each
  # worker thread stops when it sees an empty drain. This is the adapter's
  # parallel ceiling without the worker loop; BENCH_LAUNCHER=1 measures the
  # production path.
  def self.drain_concurrently(n, concurrency)
    total = [0]
    lock = Mutex.new
    started = Time.now
    threads = []
    i = 0
    while i < concurrency
      threads << Thread.new do
        while true
          delta = Sqlx::Database.with_connection { ActiveJob::DatabaseQueue.drain }
          lock.synchronize { total[0] = total[0] + delta }
          break if delta == 0
        end
      end
      i = i + 1
    end
    threads.each { |t| t.join }
    Time.now - started
  end

  def self.report_latency(label)
    rows = Sqlx::Database.with_connection do
      Sqlx::Base.rows_by_sql("SELECT (julianday(finished_at) - julianday(created_at)) * 86400.0 AS seconds FROM snails_queue_jobs WHERE status = 'succeeded'")
    end
    values = rows.map { |row| row["seconds"].to_f }
    values = values.sort
    return if values.length == 0

    p50 = values[(values.length * 50) / 100]
    p95 = values[(values.length * 95) / 100]
    puts "bench: #{label} latency p50=#{format('%.3f', p50)}s p95=#{format('%.3f', p95)}s"
  end

  def self.rate(n, seconds)
    return 0 if seconds <= 0

    (n / seconds).round
  end

  def self.report(label, n, seconds)
    puts "bench: #{label} #{n} rows in #{format('%.2f', seconds)}s (#{rate(n, seconds)} rows/s)"
  end

  # Enqueue at a steady rate for `duration_seconds`: `per_minute` arrivals
  # are spread evenly, and the loop sleeps only the time left until the
  # next slot. A busy timeout is counted and the next slot still runs; any
  # other failure ends the bench because the numbers would be partial.
  def self.enqueue_stream(duration_seconds, per_minute)
    if duration_seconds <= 0
      raise "BENCH_DURATION_SECONDS must be positive"
    end
    if per_minute <= 0
      raise "BENCH_ARRIVAL_PER_MINUTE must be positive"
    end
    interval = 60.0 / per_minute
    started = Time.now
    count = 0
    while Time.now - started < duration_seconds
      begin
        Sqlx::Database.with_connection do
          ActiveJob.enqueue(QueueBenchJob, { "i" => count })
        end
      rescue Sqlx::Busy
        ENQUEUE_BUSY[0] = ENQUEUE_BUSY[0] + 1
      end
      count = count + 1
      target = started + count * interval
      remaining = target - Time.now
      sleep(remaining) if remaining > 0
    end
    count
  end

  def self.backlog_count
    rows = Sqlx::Database.with_connection do
      Sqlx::Database.exec_read("SELECT count(*) AS n FROM snails_queue_jobs WHERE status IN ('pending', 'running')", [])
    end
    rows[0]["n"].to_i
  end

  def self.wait_for_backlog(timeout_seconds)
    started = Time.now
    while Time.now - started < timeout_seconds
      return Time.now - started if backlog_count == 0
      sleep 0.1
    end
    nil
  end

  def self.status_counts
    counts = { "pending" => 0, "running" => 0, "succeeded" => 0, "failed" => 0 }
    rows = Sqlx::Database.with_connection do
      Sqlx::Database.exec_read("SELECT status, count(*) AS n FROM snails_queue_jobs GROUP BY status", [])
    end
    rows.each { |row| counts[row["status"]] = row["n"].to_i }
    counts
  end

  # The production path: Launcher starts the scheduler and N worker
  # threads, the main thread sustains the arrival rate, then the same
  # worker threads must clear the backlog after arrivals stop. The loops
  # never return, so the process exits after printing the result.
  def self.run_launcher
    ENQUEUE_BUSY[0] = 0
    duration = (ENV["BENCH_DURATION_SECONDS"] || "60").to_i
    per_minute = (ENV["BENCH_ARRIVAL_PER_MINUTE"] || "1000").to_i
    concurrency = ActiveJob::Launcher.concurrency
    puts "bench: launcher WORKER_CONCURRENCY=#{concurrency} sleep=#{QueueBenchJob::SLEEP_MS}ms arrival=#{per_minute}/min duration=#{duration}s"

    ActiveJob.register_executor
    ActiveJob.queue_adapter = ActiveJob::DatabaseQueue
    Sqlx::Database.require_leases!
    ActiveJob::Launcher.start

    started = Time.now
    attempts = enqueue_stream(duration, per_minute)
    stopped = Time.now
    enqueued = attempts - ENQUEUE_BUSY[0]
    backlog = backlog_count
    arrival_seconds = stopped - started
    processed = enqueued - backlog
    puts "bench: launcher enqueued #{enqueued} rows in #{format('%.2f', arrival_seconds)}s (#{format('%.1f', enqueued / arrival_seconds)} rows/s; enqueue busy=#{ENQUEUE_BUSY[0]})"
    puts "bench: launcher arrival-window processed #{processed} rows (#{format('%.1f', processed / arrival_seconds)} rows/s)"
    puts "bench: launcher stop backlog #{backlog} rows"

    cleared = wait_for_backlog(120)
    if cleared.nil?
      puts "bench: launcher backlog did not clear within 120s (remaining #{backlog_count})"
    else
      drain_rate = cleared > 0 ? format('%.1f', backlog / cleared) : "n/a"
      puts "bench: launcher backlog cleared in #{format('%.2f', cleared)}s (#{drain_rate} rows/s drain)"
    end

    elapsed = Time.now - started
    report("launcher end-to-end:", enqueued, elapsed)
    report_latency("launcher")
    counts = status_counts
    puts "bench: launcher status succeeded=#{counts['succeeded']} failed=#{counts['failed']} pending=#{counts['pending']} running=#{counts['running']}"
    puts "bench: launcher sqlite busy waits are not counted (no framework surface)"
    $stdout.flush
    Tep::Sock.sphttp_exit(0)
  end

  def self.run_noop
    enqueue_s = enqueue_rows(10_000)
    report("caller path, enqueue:", 10_000, enqueue_s)

    drain_s = drain_directly(10_000)
    report("direct drain ceiling, no-op jobs:", 10_000, drain_s)

    enqueue_s = enqueue_rows(1_000)
    report("caller path, enqueue:", 1_000, enqueue_s)

    drain_s = drain_via_worker_loop(1_000)
    report("worker loop, drain (no-op jobs):", 1_000, drain_s)

    # The loop stopped on a full batch, so `LAST_DRAIN_WAS_FULL` is
    # still set. One drain that finds nothing clears it. The drain clock
    # is pushed into the future so the reading shows that signal alone
    # — a wall-clock second boundary must not answer for it.
    Sqlx::Database.with_connection { ActiveJob::DatabaseQueue.drain }
    ActiveJob::DatabaseQueue::LAST_DRAIN_AT[0] = Time.now.to_i + 3600
    puts "bench: idle after drain: drain_due? #{ActiveJob::DatabaseQueue.drain_due?} (interval resumed)"
  end

  # A representative slow profile: a body wait (`SLEEP_MS`) makes the
  # serial ceiling visible, and the direct-drain concurrency spike shows
  # what N independent worker threads buy. Each section starts from an empty
  # queue so the rows it measures are its own.
  def self.run_slow(rows, concurrency, sleep_ms)
    puts "bench: slow profile sleep=#{sleep_ms}ms rows=#{rows} concurrency=#{concurrency}"

    clear_queue
    enqueue_s = enqueue_rows(rows)
    report("caller path, enqueue (slow profile):", rows, enqueue_s)

    clear_queue
    enqueue_rows(rows)
    serial_s = drain_directly(rows)
    report("direct drain, serial (slow profile):", rows, serial_s)
    report_latency("direct drain, serial")

    clear_queue
    enqueue_rows(rows)
    concurrent_s = drain_concurrently(rows, concurrency)
    report("direct drain, concurrency #{concurrency} (slow profile):", rows, concurrent_s)
    report_latency("direct drain, concurrency #{concurrency}")

    clear_queue
    enqueue_rows(rows)
    loop_s = drain_via_worker_loop(rows)
    report("worker loop, drain (slow profile):", rows, loop_s)
    report_latency("worker loop")
  end

  def self.run(launcher_mode)
    if launcher_mode
      run_launcher
      return
    end

    sleep_ms = (ENV["BENCH_JOB_SLEEP_MS"] || "0").to_i
    concurrency_env = ENV["BENCH_CONCURRENCY"]
    run_noop if sleep_ms == 0 && (concurrency_env.nil? || concurrency_env.empty?)

    if sleep_ms > 0 || (!concurrency_env.nil? && !concurrency_env.empty?)
      rows = (ENV["BENCH_ROWS"] || "30").to_i
      concurrency = (ENV["BENCH_CONCURRENCY"] || "1").to_i
      run_slow(rows, concurrency, sleep_ms)
    end
  end
end

begin
  QueueBench.run(launcher_mode)
rescue Exception => failure
  $stderr.puts "bench failed: " + failure.class.to_s + ": " + failure.message
  if (ENV["BENCH_VERBOSE"] || "") == "1"
    $stderr.puts failure.backtrace.join("\n")
  end
  Tep::Sock.sphttp_exit(1)
end
