# The DB-backed queue adapter — the store-backed half of the adapter
# seam (`ActiveJob.queue_adapter = ActiveJob::DatabaseQueue`). A job
# travels as a row in `snails_queue_jobs` (one row per job; a finished
# row is that run's history), so queued work survives a restart and is
# readable from any process holding the same database. Row transitions
# belong to the table models — `Snails::QueueJob` (queue rows) and
# `Snails::QueueOccurrence` (the recurring-occurrence ledger); this
# class composes the adapter protocol (drain interval, batch size, orphan age)
# over them.
#
# A drain resolves the stored name back to a class (`Object.const_get`)
# and runs its class-side `perform`, so a stored name must be a
# constant path. Terminal-row retention is deliberately outside the
# adapter: `Snails::QueuePruneJob` owns it and the app puts it on the
# clock — the `generate job_queue` output prints the registration line
# commented out, so retention is opt-in per app.

module ActiveJob
  class DatabaseQueue
    # A row running longer than this belongs to a dead process — the
    # next drain returns it to pending (at-least-once: the row's
    # attempts counter has already recorded the lost run).
    ORPHANED_AFTER_SECONDS = 600

    # The most rows one drain runs — the rest waits for the next
    # drain, so one slow queue never holds the worker loop.
    BATCH_SIZE = 10

    # The seconds between idle drains: a drain that fills its batch
    # keeps the loop coming straight back on its 50ms poll, so this
    # interval gates only the idle check — the database sees one drain
    # per interval instead of one per poll while the queue is empty.
    DRAIN_INTERVAL_SECONDS = 1

    # The clock of the last drain — epoch seconds, shared state by
    # design: one adapter object serves the process's worker loop.
    LAST_DRAIN_AT = [ 0 ]

    # True when the last drain ran `BATCH_SIZE` rows — a full drain
    # means more due rows may be waiting, so the loop comes straight
    # back instead of waiting out the clock. A shorter drain clears it,
    # so an idle queue still checks once per second and no more.
    LAST_DRAIN_WAS_FULL = [ false ]

    # Guards the two flags above. `WORKER_CONCURRENCY` runs several
    # worker threads in one process, and they read/write these together; the
    # lock covers the flags only, never a drain's job time.
    DRAIN_FLAGS_LOCK = Mutex.new

    # hand off a job due now: write one pending row and return. The body does
    # not travel — the row carries the name and the payload, and a drain (this
    # process or another) resolves them when the row is claimed.
    #
    # @param job_name [String] the job's name — the stored constant path
    # @param work [Proc] the job, closed over its arguments (unused
    #   here — the row is the job)
    # @param payload [Object, nil] the serializable arguments, stored
    #   as JSON text (nil for a payload-less job)
    # @return [void]
    def self.enqueue(job_name, work, payload)
      now = Time.now.utc
      Snails::QueueJob.enqueue!(job_name, payload, now, now)
    end

    # hand off a delayed one-off: the row waits in pending until a drain's clock
    # passes `scheduled_at`. A one-off is NOT deduplicated: every call writes
    # its own row, so the same name and run time with different payloads are
    # different jobs.
    #
    # @param job_name [String] the job's name — the stored constant path
    # @param work [Proc] the job, closed over its arguments (unused here)
    # @param payload [Object, nil] the serializable arguments (JSON text)
    # @param scheduled_at [Time] the run time — the Time slot is the
    #   contract, so a non-Time never reaches the row (the .rbs pins it)
    # @return [void]
    def self.enqueue_at(job_name, work, payload, scheduled_at)
      now = Time.now.utc
      Snails::QueueJob.enqueue!(job_name, payload, scheduled_at, now)
    end

    # the recurring half: one row per (name, interval start), so several
    # processes firing the same beat still queue the occurrence once. The ledger
    # insert and the queue row are one transaction — a ledger collision (another
    # process won) answers false with no row written, so the ledger can never
    # keep an occurrence whose row was lost. A one-off `enqueue_at` never comes
    # through here.
    #
    # @param name [String] the job's name — the stored constant path
    # @param work [Proc] the job, closed over its arguments (unused here)
    # @param payload [Object, nil] the serializable arguments (unused —
    #   a recurring beat carries none)
    # @param scheduled_at [Time] the interval's start, as the beat
    #   computed it (`ActiveJob.scheduled_at_for`)
    # @return [Boolean] true when this call queued the occurrence
    def self.enqueue_once(name, work, payload, scheduled_at)
      now = Time.now.utc
      begin
        Sqlx::Base.transaction do
          Snails::QueueOccurrence.insert!(name, scheduled_at, now)
          Snails::QueueJob.enqueue!(name, payload, scheduled_at, now)
        end
        true
      rescue Sqlx::RecordNotUnique
        false
      end
    end

    # whether a drain is due: the interval passed since the last drain, OR the
    # last drain ran a full batch. A full batch means more due rows may be
    # waiting, so a worker thread (its 50ms poll) comes straight back and works
    # through the backlog; a shorter drain clears the flag and the idle interval
    # takes over. What runs inside a drain is decided by the rows, not by this
    # gate. The read is mutex-guarded: concurrent worker threads share the
    # flags.
    #
    # @return [Boolean] true when a drain should run
    def self.drain_due?
      DRAIN_FLAGS_LOCK.synchronize do
        LAST_DRAIN_WAS_FULL[0] || (Time.now.to_i - LAST_DRAIN_AT[0] >= DRAIN_INTERVAL_SECONDS)
      end
    end

    # release orphaned claims, then run up to `BATCH_SIZE` due rows oldest
    # first, and answer how many ran. An unresolvable name or a raising body is
    # recorded on its row and the drain moves on — one bad job never costs the
    # queue the rest. A worker thread calls this under its own database lease,
    # and several worker threads may call it at once: the claim is a single
    # atomic UPDATE, so the rows are split between them and never duplicated (a
    # claim that lost the race answers nil and the drain ends). The drain flags
    # are mutex-guarded; a full batch sets `LAST_DRAIN_WAS_FULL` so the next
    # drain is due at once, a shorter drain — even an empty one — clears it and
    # the idle interval takes over. With N worker threads, N rows run at once
    # (one per worker thread) and a drain processes up to `BATCH_SIZE` rows per
    # worker thread; a row abandoned by a dead process returns to pending after
    # `ORPHANED_AFTER_SECONDS`.
    #
    # @return [Integer] the number of rows this drain ran
    def self.drain
      DRAIN_FLAGS_LOCK.synchronize { LAST_DRAIN_AT[0] = Time.now.to_i }
      now = Time.now.utc
      Snails::QueueJob.release_orphaned!(now - ORPHANED_AFTER_SECONDS, now)
      processed = 0
      while processed < BATCH_SIZE
        job = Snails::QueueJob.claim_due(now)
        break if job.nil?
        perform_claimed(job)
        processed = processed + 1
      end
      DRAIN_FLAGS_LOCK.synchronize { LAST_DRAIN_WAS_FULL[0] = processed >= BATCH_SIZE }
      processed
    end

    # Run one claimed row and record the outcome on it: the stored name
    # resolves to a class (`Object.const_get`) whose class-side
    # `perform` receives the decoded payload (nil when none). A failure —
    # a name no class carries, or a body raising anything the boundary
    # does not re-raise — becomes a `job.failed` record and lands on the
    # row as `failed` with the exception's class and message; there are no
    # retries, so the recorded row is the whole story. Control and fatal
    # exceptions leave the boundary and are not recorded as job failures.
    #
    # The job's `snails.db_ms` is the DB time between `begin_job` and the
    # record; it includes the queue's own mark SQL and any DB work the body
    # did. The batch claim runs before `begin_job`, so it stays outside the
    # per-job window.
    def self.perform_claimed(job)
      name = job.name
      Snails::Logger::Context.begin_job(name, job.id, job.attempts)
      started = Time.now
      begin
        Snails.logger.debug("job " + name + " started", event: "job.started")
        Object.const_get(name).perform(job.payload)
        Snails::QueueJob.mark_succeeded!(job.id, Time.now.utc)
        log_job_finished(name, started)
      rescue Exception => failure
        raise if Snails::ErrorBoundary.fatal?(failure)
        begin
          Snails::QueueJob.mark_failed!(job.id, failure.class.to_s + ": " + failure.message, Time.now.utc)
        ensure
          log_job_failed(name, started, failure)
        end
      ensure
        Snails::Logger::Context.end_job
      end
    end

    # The finished/failed records carry the job's context fields, the run's
    # duration, and the DB time accumulated while serving the job — queue
    # bookkeeping included.
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

    # private on purpose: the drain is this class's own unit — outside
    # callers reach queued jobs through `drain`, never row by row.
    private_class_method :perform_claimed, :log_job_finished, :log_job_failed, :elapsed_ms
  end
end
