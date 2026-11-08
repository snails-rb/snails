# The job stack's periodic half: the registry of recurring callbacks and the
# loop that fires them once per calendar bucket. `ActiveJob.recurring`
# registers here; `ActiveJob::Launcher.start` runs the loop.
module ActiveJob
  module Scheduler
    # How often the scheduler loop looks for due buckets, in seconds. A
    # cooperative poll rather than a wakeup because the callback registry is a
    # plain Array owned by this process.
    POLL_INTERVAL = 0.05

    # the periodic callbacks the scheduler runs, one entry per registration.
    # Process-local like the job queue: every server process runs its own
    # scheduler, so a callback that must not double-run across processes takes a
    # lease of its own.
    #
    # A Hash per entry rather than an array triple: an element write
    # (`entry["last_bucket"] = …`) is a shape the compiler handles; an index
    # write (`entry[1] = …`) is not.
    PERIODIC = []

    # add a beat the scheduler runs once per `seconds`-second interval, keyed to
    # the interval's CALENDAR bucket: the scheduler fires when the current
    # bucket (epoch floored to the interval — the same grid
    # `ActiveJob.scheduled_at_for` stamps a recurring `scheduled_at` with)
    # differs from the last bucket this entry fired. A fresh entry carries no
    # bucket, so its first run fires the current one — a process that restarts
    # more often than its interval still covers every bucket it was alive for,
    # instead of waiting out a full interval from each boot (an uptime-anchored
    # first fire starves retention-class beats under frequent deploys). Buckets
    # that passed while no process was alive are not backfilled: only the
    # current bucket is covered. An app declares periodic work through
    # `ActiveJob.recurring`, which registers the beat here. The callback runs on
    # the scheduler's thread with its own `Sqlx::Database` lease, so it may
    # touch models. The proc argument (not a block) mirrors `ActiveJob.enqueue`:
    # the RBS cannot type a captured `&block`. A non-positive interval is
    # rejected here — the bucket arithmetic below would divide by zero, and
    # registration is the point that can still name the bad value.
    #
    # @param seconds [Integer] seconds per bucket
    # @param work [Proc] the zero-argument callback the scheduler invokes
    # @return [void]
    # @raise [ArgumentError] when the interval is not a positive Integer
    def self.register_periodic(seconds, work)
      interval = Integer(seconds)
      if interval <= 0
        raise ArgumentError, "periodic interval must be positive seconds, got #{interval}"
      end
      PERIODIC << { "interval" => interval, "last_bucket" => nil, "work" => work }
    end

    # fire every callback whose calendar bucket has advanced since its last
    # fire, and record that bucket as fired. Recording happens before the call,
    # so a raising callback still counts as its bucket's attempt — the next fire
    # is the next bucket, not a retry loop inside this one. The scheduler calls
    # this each poll; a callback that raises becomes a
    # `scheduler.callback_failed` record and does not stop the others (the job
    # drain's rule) or the loop. Control and fatal exceptions propagate to the
    # scheduler loop. `now` is injectable so the contract is testable without
    # sleeping.
    #
    # @param now [Integer] the epoch second the bucket check runs against
    # @return [void]
    def self.run_periodic(now = Time.now.to_i)
      PERIODIC.each do |entry|
        bucket = now - (now % entry["interval"])
        next if entry["last_bucket"] == bucket

        entry["last_bucket"] = bucket
        begin
          Sqlx::Database.with_connection { entry["work"].call }
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

    # the scheduler loop: poll, fire the due callbacks, and repeat.
    # `Launcher.start` gives it its own thread; it never drains the queue. A
    # beat only enqueues its job (`ActiveJob.recurring`); `Worker.run` executes
    # the queued job. A failure in the run is reported by `fire_due_callbacks`
    # and the next run still fires; a control or fatal exception stops the loop
    # and is reported here.
    #
    # @return [void]
    def self.run
      while true
        sleep(POLL_INTERVAL)
        fire_due_callbacks
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

    # Fire the due periodic callbacks without the sleep. `run_periodic`
    # isolates each callback; this boundary isolates a structural failure in
    # the run itself, so the scheduler loop only stops on a control or fatal
    # exception. The scheduler calls it after each sleep.
    def self.fire_due_callbacks
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

    private_class_method :fire_due_callbacks
  end
end
