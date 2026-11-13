# The drain loop: poll the queue adapter, run one drain, repeat.
# `ActiveJob::Launcher.start` spawns one per worker thread, alongside the
# scheduler loop.
#
# A recurring beat only enqueues the job; this loop executes it like any other.

module ActiveJob
  module Worker
    # How often the drain loop looks for work, in seconds. A cooperative poll
    # rather than a wakeup because there is nothing to wake on: the queue is a
    # plain Array and an enqueue happens on another fiber inside the same
    # process.
    POLL_INTERVAL = 0.05

    # the drain loop: poll, run one drain, and repeat. The launcher spawns one
    # of these per worker thread; `register_executor` flips `enqueue` from
    # call-site execution to queueing, and this loop is what makes the queue
    # real. It executes one-off, delayed, and recurring jobs alike (the
    # scheduler only enqueues the last). `WORKER_CONCURRENCY` runs more side by
    # side — the adapter's claim is atomic so rows are split between them, but
    # the global FIFO order is only guaranteed at one. Each worker thread holds
    # its own Sqlx::Database lease, so `DATABASE_POOL_SIZE` must cover worker
    # threads plus request threads. The loop holds no queue knowledge: each
    # iteration asks whether a drain is due (`drain_due?` — the process queue is
    # due when work is waiting, the DB adapter samples its rows ~1s) and drains
    # through the same slot. A job runs outside any request's
    # `Sqlx::Database.with_connection`, so touching a model without one would
    # borrow whichever handle a request happened to be using. Nothing is retried
    # and nothing survives a restart on the process-local queue; the DB rows are
    # the restart-surviving half.
    #
    # @return [void]
    def self.run
      while true
        sleep(POLL_INTERVAL)
        drain_once
      end
    rescue Exception => failure
      Snails.logger.error(
        "worker drain loop stopped",
        event: "worker.loop_stopped",
        fields: { "pid" => Process.pid },
        exception: failure
      )
      raise
    end

    # One drain without the sleep: drive the adapter. A drain is one unit — an
    # adapter or drain failure becomes a `worker.drain_failed` record and the
    # next drain still runs; control and fatal exceptions propagate. The loop
    # calls it after each sleep.
    def self.drain_once
      begin
        if ActiveJob.queue_adapter.drain_due?
          Sqlx::Database.with_connection { ActiveJob.queue_adapter.drain }
        end
      rescue Exception => failure
        raise if Snails::ErrorBoundary.fatal?(failure)
        Snails.logger.error(
          "worker drain failed",
          event: "worker.drain_failed",
          fields: { "pid" => Process.pid },
          exception: failure
        )
      end
    end

    private_class_method :drain_once
  end
end
