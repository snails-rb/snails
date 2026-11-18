# The job stack's periodic half: the registry of recurring callbacks and the
# loop that runs them once per occurrence. An occurrence is one scheduled run:
# the interval window's start, or the cron expression's scheduled time.
# `ActiveJob.recurring` registers here; `ActiveJob::Launcher.start` runs the loop.
# A fresh entry starts at the next occurrence after its first pass; an
# occurrence that passed while no process was alive is not caught up.
module ActiveJob
  module Scheduler
    # How often the scheduler loop looks for a due callback, in seconds. A
    # cooperative poll rather than a wakeup because the callback registry is a
    # plain Array owned by this process.
    POLL_INTERVAL = 0.05

    # the periodic callbacks the scheduler runs, one entry per registration.
    # Process-local like the job queue: every server process runs its own
    # scheduler, so a callback that must not double-run across processes takes a
    # lease of its own.
    #
    # One recurrence form per entry: `interval` (seconds) or `cron` (a parsed
    # `Snails::Cron`), never both. `last_occurrence` is the occurrence the entry
    # has handled: the first pass adopts the covering one without running it, and
    # later passes record each run before the callback.
    #
    # A Hash per entry rather than an array triple: an element write
    # (`entry["last_occurrence"] = …`) is a shape the compiler handles; an index
    # write (`entry[1] = …`) is not.
    PERIODIC = []

    # add a periodic callback the scheduler runs once per `seconds`-second
    # interval, keyed to the interval window: the scheduler runs it when the
    # occurrence (epoch floored to the interval — the same window
    # `ActiveJob.scheduled_at_for` uses for a recurring `scheduled_at`) differs
    # from the last occurrence this entry handled. A fresh entry adopts the
    # occurrence that covers its first pass without running it, so a process
    # that starts late waits for the next window instead of catching up; a
    # window that passed while no process was alive is not backfilled (the rule
    # Solid Queue's scheduler follows). An app declares periodic work through
    # `ActiveJob.recurring`, which registers the callback here. The callback runs
    # on the scheduler's thread with its own `Sqlx::Database` lease, so it may
    # touch models. The proc argument (not a block) mirrors `ActiveJob.enqueue`:
    # the RBS cannot type a captured `&block`. A non-positive interval is
    # rejected here — the window arithmetic below would divide by zero, and
    # registration is the point that can still name the bad value.
    #
    # @param seconds [Integer] seconds per window
    # @param work [Proc] the callback the scheduler invokes with the occurrence
    #   it runs for, as epoch seconds
    # @return [void]
    # @raise [ArgumentError] when the interval is not a positive Integer
    def self.register_interval(seconds, work)
      interval = Integer(seconds)
      if interval <= 0
        raise ArgumentError, "periodic interval must be positive seconds, got #{interval}"
      end
      PERIODIC << { "interval" => interval, "cron" => nil, "last_occurrence" => nil, "work" => work }
    end

    # add a periodic callback the scheduler runs at a cron expression's
    # occurrences: the scheduler runs it when the occurrence that covers now —
    # the latest scheduled time at or before it — differs from the last one this
    # entry handled. A fresh entry adopts that occurrence without running it, so
    # a process that starts after the scheduled time waits for the next
    # occurrence instead of catching up. Occurrences that passed while no
    # process was alive are not backfilled. A cron expression is evaluated in
    # UTC.
    #
    # @param cron [Snails::Cron] the parsed expression (`Snails::Cron.parse`)
    # @param work [Proc] the callback the scheduler invokes with the occurrence
    #   it runs for, as epoch seconds
    # @return [void]
    def self.register_cron(cron, work)
      PERIODIC << { "interval" => nil, "cron" => cron, "last_occurrence" => nil, "work" => work }
    end

    # run every callback whose occurrence has advanced since its last run, and
    # record that occurrence as handled. The first pass after registration
    # adopts the covering occurrence without running it: a process that starts
    # after the scheduled time waits for the next occurrence instead of
    # catching up. After that, recording happens before the call, so a raising
    # callback still counts as its occurrence's attempt — the next run is the
    # next occurrence, not a retry loop inside this one. The scheduler calls
    # this each poll; a callback that raises becomes a
    # `scheduler.callback_failed` record and does not stop the others (the job
    # drain's rule) or the loop. Control and fatal exceptions propagate to the
    # scheduler loop. `now` is injectable so the contract is testable without
    # sleeping.
    #
    # @param now [Integer] the epoch second the occurrence check runs against
    # @return [void]
    def self.run_periodic(now = Time.now.to_i)
      PERIODIC.each do |entry|
        occurrence = occurrence_at_or_before(entry, now)
        if entry["last_occurrence"] == nil
          entry["last_occurrence"] = occurrence
          next
        end
        next if entry["last_occurrence"] == occurrence

        entry["last_occurrence"] = occurrence
        begin
          Sqlx::Database.with_connection { entry["work"].call(occurrence) }
        rescue Exception => failure
          raise if Snails::ErrorBoundary.fatal?(failure)
          Snails.logger.error(
            "periodic callback failed",
            event: "scheduler.callback_failed",
            fields: { "pid" => Process.pid },
            exception: failure
          )
        end
      end
    end

    # the scheduler loop: poll, run the due callbacks, and repeat.
    # `Launcher.start` gives it its own thread; it never drains the queue. A
    # callback only enqueues its job (`ActiveJob.recurring`); `Worker.run`
    # executes the queued job. A failure in the run is reported by
    # `run_due_callbacks` and the next run still happens; a control or fatal
    # exception stops the loop and is reported here.
    #
    # @return [void]
    def self.run
      while true
        sleep(POLL_INTERVAL)
        run_due_callbacks
      end
    rescue Exception => failure
      Snails.logger.error(
        "scheduler loop stopped",
        event: "scheduler.loop_stopped",
        fields: { "pid" => Process.pid },
        exception: failure
      )
      raise
    end

    # Run the due periodic callbacks without the sleep. `run_periodic`
    # isolates each callback; this boundary isolates a structural failure in
    # the run itself, so the scheduler loop only stops on a control or fatal
    # exception. The scheduler calls it after each sleep.
    def self.run_due_callbacks
      run_periodic
    rescue Exception => failure
      raise if Snails::ErrorBoundary.fatal?(failure)
      Snails.logger.error(
        "periodic run failed",
        event: "scheduler.run_failed",
        fields: { "pid" => Process.pid },
        exception: failure
      )
    end

    # the occurrence that covers `now` for one entry, as epoch seconds: the
    # interval window's start, or the cron expression's latest scheduled time at
    # or before it. The loop's gate and the enqueue key are this one value — the
    # entry records it, and the callback receives it.
    def self.occurrence_at_or_before(entry, now)
      if entry["cron"] != nil
        entry["cron"].occurrence_at_or_before(now)
      else
        now - (now % entry["interval"])
      end
    end

    # private on purpose: these serve `run_periodic` and the loop.
    private_class_method :run_due_callbacks, :occurrence_at_or_before
  end
end
