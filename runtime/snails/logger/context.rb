# frozen_string_literal: true

# The log values that belong to one request or one job — request id, matched
# controller/action/format, the active trace, DB time, job name/id/attempt —
# stored per thread.
#
# Values can cross connections on a fiber-per-connection server. The request
# id is kept until the next request clears it; the server rescue still needs it.
# The trace values are a mirror the tracer writes when the span stack changes;
# the logger reads them without asking `Snails.tracer`, which keeps the
# logger below the tracer instead of creating a two-way dependency.
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

      # the controller class name the router matched, or "" when a request
      # matched none (a 404, a 400, or an app-owned dispatch); nil outside a
      # request.
      #
      # @return [String, nil] the matched controller name
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

      # the action the router matched, or "" when a request matched none; nil
      # outside a request.
      #
      # @return [String, nil] the matched action name
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

      # the request format (`json` by default), or "" when a request matched
      # none; nil outside a request.
      #
      # @return [String, nil] the request format
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

      # the active span's trace correlation, or nil when tracing is off or no
      # span is current. The values are OTel log record fields: the hex trace
      # and span ids and the sampled trace flags. The tracer mirrors the
      # innermost span into this bag; the logger reads it and never asks the
      # tracer.
      #
      # @return [Hash{String => Object}, nil] trace ids and flags, or nil
      def self.trace
        trace_id = Thread.current[:snails_log_trace_id]
        return nil if trace_id.nil?

        {
          "trace_id" => trace_id,
          "span_id" => Thread.current[:snails_log_span_id],
          "trace_flags" => Thread.current[:snails_log_trace_flags]
        }
      end

      # mirror the current span for log correlation. The tracer calls this
      # whenever its span stack changes; the ids are validated where the span
      # is created, so this only rejects a missing or out-of-range field.
      #
      # @api internal
      # @param trace_id [String] the 32-hex trace id
      # @param span_id [String] the 16-hex current span id
      # @param trace_flags [Integer] the OTel trace flags byte
      # @raise [ArgumentError] an id is empty or the flags byte is out of range
      # @return [void]
      def self.set_trace(trace_id, span_id, trace_flags)
        if !trace_id.is_a?(String) || trace_id.empty? || !span_id.is_a?(String) || span_id.empty?
          raise ArgumentError, "Snails::Logger::Context trace expects non-empty trace_id and span_id"
        end
        if !trace_flags.is_a?(Integer) || trace_flags < 0 || trace_flags > 255
          raise ArgumentError, "Snails::Logger::Context trace_flags expects an Integer between 0 and 255"
        end

        Thread.current[:snails_log_trace_id] = trace_id
        Thread.current[:snails_log_span_id] = span_id
        Thread.current[:snails_log_trace_flags] = trace_flags
      end

      # clear the mirrored trace. The request and job boundaries call it so a
      # reused thread cannot attach the previous unit's ids to new records.
      #
      # @api internal
      # @return [void]
      def self.clear_trace
        Thread.current[:snails_log_trace_id] = nil
        Thread.current[:snails_log_span_id] = nil
        Thread.current[:snails_log_trace_flags] = nil
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
      # in-process job has no row id or attempt, so both may be nil; the
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
        clear_trace
      end

      # clear the job values and the DB accumulator after a run.
      #
      # @return [void]
      def self.end_job
        Thread.current[:snails_log_job_name] = nil
        Thread.current[:snails_log_job_id] = nil
        Thread.current[:snails_log_job_attempt] = nil
        Thread.current[:snails_log_db_us] = nil
        clear_trace
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
        clear_trace
        id
      end
    end
  end
end
