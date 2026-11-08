# The job stack's process-local launcher: starts the scheduler loop and N
# drain loops on new threads of the server process. The servers call `start`
# once per server process from their connection loop (prefork children
# included); an out-of-process worker would be this module behind a different
# entry.
module ActiveJob
  module Launcher
    # run the scheduler and the drain loops on new threads of THIS process,
    # registering the logger's periodic flush on that scheduler first
    # (`Snails.logger.register_flush`), so the beat exists before the loop
    # iterates the registry. The servers call it once per server process, from
    # their connection loop — after any prefork, so every child drains the queue
    # its requests enqueue to. A thread started before the fork would not exist
    # in the children: fork carries only the forking thread. The scheduler and
    # the drain loops are separate loops so a slow job cannot delay a periodic
    # beat. `WORKER_CONCURRENCY` decides the worker thread count, one by
    # default: throughput and FIFO order stay unchanged unless the app opts in.
    #
    # @return [void]
    def self.start
      Snails.logger.register_flush
      Thread.new do
        Scheduler.run
      end
      n = concurrency
      i = 0
      while i < n
        Thread.new do
          Worker.run
        end
        i = i + 1
      end
    end

    # How many worker threads `start` runs: `WORKER_CONCURRENCY`, one when it is
    # unset or empty. A value that is not a positive integer fails at boot
    # instead of silently running one worker thread against the app's
    # expectation. Public because `process.started` reports the effective count.
    def self.concurrency
      value = ENV["WORKER_CONCURRENCY"]
      return 1 if value.nil? || value.empty?
      message = "WORKER_CONCURRENCY must be a positive integer, got " + value.inspect
      begin
        n = Integer(value)
      rescue ArgumentError
        raise ArgumentError, message
      end
      if n < 1
        raise ArgumentError, message
      end
      n
    end
  end
end
