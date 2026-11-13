# frozen_string_literal: true

# The log values that belong to one request or one job — request id, matched
# controller/action/format, DB time, job name/id/attempt — stored per thread.
#
# Values can cross connections on a fiber-per-connection server. The request
# id is kept until the next request clears it; the server rescue still needs it.
require "securerandom"

module Snails
  class Logger
    module Context
      # the id of the request this thread is serving, or nil outside a request.
      #
      # @return [String, nil] the current request id
      def self.request_id
        Thread.current[:snails_log_request_id]
      end

      # the controller class name the router matched, or "" when no controller
      # ran (a 404, a 400, or an app-owned dispatch).
      #
      # @return [String] the matched controller name
      def self.controller
        Thread.current[:snails_log_controller]
      end

      # record the matched controller for the request line.
      #
      # @param name [String] the controller class name
      # @return [String] the assigned name
      def self.controller=(name)
        Thread.current[:snails_log_controller] = name
      end

      # the action the router matched, or "".
      #
      # @return [String] the matched action name
      def self.action
        Thread.current[:snails_log_action]
      end

      # record the matched action.
      #
      # @param name [String] the action name
      # @return [String] the assigned name
      def self.action=(name)
        Thread.current[:snails_log_action] = name
      end

      # the request format (`json` by default), or "".
      #
      # @return [String] the request format
      def self.format
        Thread.current[:snails_log_format]
      end

      # record the request format.
      #
      # @param name [String] the format name
      # @return [String] the assigned name
      def self.format=(name)
        Thread.current[:snails_log_format] = name
      end

      # one reading of the monotonic clock in microseconds. `Tep::App` measures
      # the request duration with the same clock, so the summary fields are
      # comparable.
      #
      # @return [Integer] microseconds since an unspecified fixed point
      def self.now_us
        (Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000000.0).to_i
      end

      # the DB time accumulated for this request or job, or 0 outside both. The
      # value is a subset of the request or job duration, not the remainder:
      # routing, JSON rendering, and the SQLite connection lease sit outside the
      # DB adapter's statement entries.
      #
      # @return [Integer] microseconds spent inside the DB adapter
      def self.db_us
        Thread.current[:snails_log_db_us] || 0
      end

      # add one statement's elapsed time to the current request or job. A call
      # outside both is a no-op: boot and non-job DB work has no record to
      # report it on.
      #
      # @param microseconds [Integer] the statement's elapsed time
      # @return [void]
      def self.add_db_us(microseconds)
        current = Thread.current[:snails_log_db_us]
        return if current.nil?

        Thread.current[:snails_log_db_us] = current + microseconds
      end

      # the job running on this thread, or nil.
      #
      # @return [String, nil] the job's class name
      def self.job_name
        Thread.current[:snails_log_job_name]
      end

      # record the running job's class name.
      #
      # @param name [String, nil] the job's class name
      # @return [String, nil] the assigned name
      def self.job_name=(name)
        Thread.current[:snails_log_job_name] = name
      end

      # the running job's id, or nil.
      #
      # @return [Integer, nil] the job id
      def self.job_id
        Thread.current[:snails_log_job_id]
      end

      # record the running job's id.
      #
      # @param id [Integer, nil] the job id
      # @return [Integer, nil] the assigned id
      def self.job_id=(id)
        Thread.current[:snails_log_job_id] = id
      end

      # the running job's attempt number, or nil.
      #
      # @return [Integer, nil] the attempt number
      def self.job_attempt
        Thread.current[:snails_log_job_attempt]
      end

      # whether the job running on this thread must not have its
      # `job.started`/`job.finished`/`job.failed` records written. The log
      # delivery job is the one job that answers yes: those records would be
      # delivered by the very transport that enqueues it, so each run would feed
      # the next one. A thread outside a job answers no.
      #
      # @return [Boolean] true when the running job's events stay unwritten
      def self.job_events_suppressed?
        Thread.current[:snails_log_job_name] == Snails::LogDeliveryJob.name
      end

      # record the running job's attempt number.
      #
      # @param attempt [Integer, nil] the attempt number
      # @return [Integer, nil] the assigned attempt
      def self.job_attempt=(attempt)
        Thread.current[:snails_log_job_attempt] = attempt
      end

      # set the job values a worker loop carries while it runs one job, and
      # reset the DB accumulator. The job's `ensure` calls `end_job` so a reused
      # worker thread never leaks the previous job's identity or DB time. A
      # process-local job has no row id or attempt, so both may be nil; the
      # logger then omits those fields.
      #
      # @param name [String] the job's class name
      # @param id [Integer, nil] the job id
      # @param attempt [Integer, nil] the attempt number
      # @return [void]
      def self.begin_job(name, id, attempt)
        Thread.current[:snails_log_job_name] = name
        Thread.current[:snails_log_job_id] = id
        Thread.current[:snails_log_job_attempt] = attempt
        Thread.current[:snails_log_db_us] = 0
      end

      # clear the job values and the DB accumulator after a run.
      #
      # @return [void]
      def self.end_job
        Thread.current[:snails_log_job_name] = nil
        Thread.current[:snails_log_job_id] = nil
        Thread.current[:snails_log_job_attempt] = nil
        Thread.current[:snails_log_db_us] = nil
      end

      # start a new request: mint the id, clear the matched and job fields, and
      # reset the DB accumulator. The id is short on purpose: it only has to
      # separate lines within one log stream, and the pid already separates
      # workers.
      #
      # @return [String] the new request id
      def self.begin_request
        id = SecureRandom.hex(4)
        Thread.current[:snails_log_request_id] = id
        Thread.current[:snails_log_controller] = ""
        Thread.current[:snails_log_action] = ""
        Thread.current[:snails_log_format] = ""
        Thread.current[:snails_log_db_us] = 0
        Thread.current[:snails_log_job_name] = nil
        Thread.current[:snails_log_job_id] = nil
        Thread.current[:snails_log_job_attempt] = nil
        id
      end
    end
  end
end
