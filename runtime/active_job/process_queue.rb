# The default queue adapter: jobs live as procs in this process's memory, so
# nothing crosses a process or a restart.
#
# Adapter method names must stay unique program-wide, or class-side dispatch
# through `ActiveJob.queue_adapter` collides with a builtin and fails at runtime.

module ActiveJob
  class ProcessQueue
    # The most jobs the queue holds. A producer can outrun the drain — a slow
    # log receiver makes `LogDeliveryJob` entries accumulate faster than the
    # worker executes them — and an unbounded Array would grow the process to
    # OOM. The bound is a safety valve, not a throughput target: when it is
    # reached the new job is dropped and reported locally once per overflow
    # episode. 1,000 entries stays far above the batches a healthy 100-record
    # flush produces in one flush interval.
    MAX_PENDING = 1_000

    # The queue: one entry per job — a Hash carrying the zero-argument proc and
    # its due time (`due_at`, epoch seconds; `enqueue` writes 0, `enqueue_at`
    # the scheduled run time). Requests enqueue from their own threads and
    # worker threads run the due jobs, so both ends run under a lock — and
    # `drain` runs the due jobs OUTSIDE the lock, so a slow job never holds the
    # queue against requests still enqueueing. One drain takes the whole due
    # set, so several worker threads do not split a backlog; they can split
    # jobs enqueued while another drain is running. Throughput parallelism
    # lives in the DB adapter, which claims one row at a time.
    PENDING = []
    QUEUE_LOCK = Mutex.new

    # Whether this overflow episode already wrote its warning. The warning is
    # local-only (`report_local`) so it cannot enqueue a log delivery job and
    # feed the backlog it reports. The flag re-arms after a drain leaves the
    # queue at or below half the bound.
    OVERFLOW_REPORTED = [ false ]

    # Process-local monotonic job id: the process queue has no stored row, so
    # the id only has to be unique within this process's lifetime. It resets
    # on restart and is not a cross-process correlation key.
    NEXT_ID = [ 0 ]

    # put a job on the queue, due now. The name and payload are part of the
    # adapter interface — `enqueue` passes all three to whichever adapter is
    # selected — but this adapter keeps only the name (for the run's record);
    # the proc IS the job, closed over its arguments. A full queue refuses the
    # new job instead of growing without bound; the refusal is reported locally
    # once per overflow episode.
    #
    # @param job_name [String] the job's class name, kept for the run's record
    # @param work [Proc] the job, closed over its arguments
    # @param payload [Object, nil] the serializable arguments (unused here)
    # @return [void]
    def self.enqueue(job_name, work, payload)
      add_pending(job_name, work, 0)
    end

    # put a job on the queue with a run time: the drain leaves it unrun until
    # the clock (`Time.now`) passes `scheduled_at`. A store-backed adapter
    # stores the same value in its row instead; the time is the whole difference
    # from `enqueue` here. The Time slot refuses a non-Time argument at the
    # build or the call boundary (ext/time.rb), so no in-body guard stands here.
    # The same bound and refusal rule as `enqueue` applies: a scheduled job
    # waiting for its time counts against the queue.
    #
    # @param job_name [String] the job's class name, kept for the run's record
    # @param work [Proc] the job, closed over its arguments
    # @param payload [Object, nil] the serializable arguments (unused here)
    # @param scheduled_at [Time] the run time
    # @return [void]
    def self.enqueue_at(job_name, work, payload, scheduled_at)
      add_pending(job_name, work, scheduled_at.to_i)
    end

    # the recurring half of the adapter interface: this adapter is
    # process-local, so the run's scheduled time has no cross-process work to do
    # — the call runs the `enqueue` path. A store-backed adapter keys its row by
    # (name, scheduled_at) under a unique constraint instead.
    #
    # It answers whether THIS call enqueued the job: the process-local
    # queue has no cross-process duplicate to drop, so it answers true
    # unless the queue is full; a store-backed adapter answers false for an
    # existing (name, scheduled_at) row.
    #
    # @return [Boolean] true when this call enqueued the job
    def self.enqueue_once(name, work, payload, scheduled_at)
      add_pending(name, work, 0)
    end

    # run every due job, in queue order, and answer how many ran. A job
    # scheduled for a later time stays queued (`due_at` gates it); a job that
    # enqueues another is reached by the same drain. The worker loop calls it
    # (inside the loop's Sqlx::Database lease); the contract tests call it
    # directly. A unit failure — anything the boundary does not re-raise — is
    # one lost job, never a lost drain: `job.failed` records it and the queue
    # moves on (an unhandled job error must not take the other jobs, or the
    # process, with it). Control and fatal exceptions propagate. Each run sets
    # the job values `Context` carries, so the records name the job.
    #
    # @return [Integer] the number of jobs that ran
    def self.drain
      ran = 0
      while true
        due = []
        QUEUE_LOCK.synchronize do
          kept = []
          i = 0
          while i < PENDING.length
            entry = PENDING[i]
            if entry["due_at"] <= Time.now.to_i
              due << entry
            else
              kept << entry
            end
            i = i + 1
          end
          PENDING.clear
          i = 0
          while i < kept.length
            PENDING << kept[i]
            i = i + 1
          end
          if OVERFLOW_REPORTED[0] && PENDING.length <= MAX_PENDING / 2
            OVERFLOW_REPORTED[0] = false
          end
        end
        break if due.length == 0
        i = 0
        while i < due.length
          entry = due[i]
          name = entry["name"]
          Snails::Logger::Context.begin_job(name, entry["job_id"], entry["attempt"])
          started = Time.now
          begin
            Snails.logger.debug("job " + name + " started", event: "job.started")
            entry["work"].call
            ran = ran + 1
            log_job_finished(name, started)
          rescue Exception => failure
            raise if Snails::ErrorBoundary.fatal?(failure)
            log_job_failed(name, started, failure)
          ensure
            Snails::Logger::Context.end_job
          end
          i = i + 1
        end
      end
      ran
    end

    # The finished/failed records carry the job's context fields, the run's
    # duration, and the DB time accumulated while serving the job.
    def self.log_job_finished(name, started)
      Snails.logger.info(
        "job " + name + " succeeded",
        event: "job.finished",
        fields: {
          "snails.job.status" => "succeeded",
          "snails.duration_ms" => elapsed_ms(started),
          "snails.db_ms" => Snails::Logger::Context.db_us / 1000.0
        }
      )
    end

    def self.log_job_failed(name, started, failure)
      Snails.logger.error(
        "job " + name + " failed",
        event: "job.failed",
        fields: {
          "snails.job.status" => "failed",
          "snails.duration_ms" => elapsed_ms(started),
          "snails.db_ms" => Snails::Logger::Context.db_us / 1000.0
        },
        exception: failure
      )
    end

    def self.elapsed_ms(started)
      (Time.now - started) * 1000.0
    end

    # how many jobs are waiting (a scheduled job counts as waiting until its
    # time passes). The contract tests read it; the worker loop's due check goes
    # through `drain_due?`.
    #
    # @return [Integer] the number of queued jobs
    def self.pending_count
      n = 0
      QUEUE_LOCK.synchronize do
        n = PENDING.length
      end
      n
    end

    # whether a drain should run now: at least one entry's time has passed. A
    # queue that holds only future jobs answers false until the clock reaches
    # them.
    #
    # @return [Boolean] true when any queued job is due
    def self.drain_due?
      now = Time.now.to_i
      due = false
      QUEUE_LOCK.synchronize do
        i = 0
        while i < PENDING.length
          if PENDING[i]["due_at"] <= now
            due = true
          end
          i = i + 1
        end
      end
      due
    end

    # Append one entry unless the bound is reached; answer whether it landed.
    # The overflow warning is written after the queue lock is released so a
    # slow local output cannot hold the queue against a drain.
    def self.add_pending(job_name, work, due_at)
      queued = false
      QUEUE_LOCK.synchronize do
        if PENDING.length < MAX_PENDING
          NEXT_ID[0] = NEXT_ID[0] + 1
          PENDING << {
            "due_at" => due_at, "job_id" => NEXT_ID[0], "attempt" => 1,
            "name" => job_name, "work" => work
          }
          queued = true
        end
      end
      report_full(job_name) unless queued
      queued
    end

    # One local line per overflow episode. It must not become a log record:
    # a record would enqueue another delivery job into the full queue. The
    # line names the dropped job and the bound so the operator can raise
    # worker throughput or move the queue to a store-backed adapter.
    def self.report_full(job_name)
      report = false
      QUEUE_LOCK.synchronize do
        if !OVERFLOW_REPORTED[0]
          OVERFLOW_REPORTED[0] = true
          report = true
        end
      end
      return unless report

      Snails.logger.report_local(
        :warn,
        "[queue] dropped " + job_name + ": process queue is full (limit " +
          MAX_PENDING.to_s + " pending); further drops stay quiet until the queue drains — " +
          "increase WORKER_CONCURRENCY or use a store-backed adapter"
      )
    end

    private_class_method :log_job_finished, :log_job_failed, :elapsed_ms,
                         :add_pending, :report_full
  end
end
