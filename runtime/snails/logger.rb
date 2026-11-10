# frozen_string_literal: true

# the one write path: every call writes a local line and, when a transport is
# configured, hands the same event over as a structured
# `Snails::Logger::Record`. The line is for a human reading a terminal; the
# record is the contract a remote destination or a JSON sink consumes.
#
# Every setting an app may want to change is a slot it sets once in
# `config/environment.rb`:
#
#   Snails.logger.level           = :info
#   Snails.logger.output          = $stdout
#   Snails.logger.formatter       = MyFormatter.new
#   Snails.logger.record_formatter = MyRecordFormatter.new
#   Snails.logger.transport       = MyTransport.new
#   Snails.logger.host_name       = "api-1"
#   Snails.logger.progname        = "api"
#
# The five level methods take an optional `event:` name with `fields:` and
# `exception:`. A call with only a message is a plain line rendered by
# `formatter` plus an `app.log` record; a call with `event:` is a named
# record rendered by `record_formatter`. Both reach the transport, so the
# formatter choice never decides whether something is delivered. The
# external hand-off lives in `Snails::Logger::Delivery`; this class owns the
# local line and the one-line transport-failure report. A server process
# calls `after_fork` after any prefork and `register_flush` before the loops
# start; the scheduler then calls `flush` once per second.
#
# The defaults keep a development server verbose and a deployed one
# quiet: `debug` is written only in development, every other level in
# every mode. There is no level environment variable — the mode comes
# from SNAILS_ENV and the rest is the app's environment file.
module Snails
  # the process-wide logger. Memoized so the slots set in config/environment.rb
  # land on the same object every call writes through.
  #
  # @return [Logger] the shared logger
  def self.logger
    @logger ||= Logger.new
  end

  # the runtime's one logger. Apps call the five level methods — with `event:`
  # when the call is a structured event — and configure the slots above.
  class Logger
    def initialize
      @level = nil
      @output = nil
      @formatter = Formatter.new
      @record_formatter = RecordFormatter.new
      @delivery = Delivery.new
      @progname = ""
      @host_name = nil
      # The output whose sync mode this process already turned on. Held by
      # identity so an in-process `$stderr` swap is noticed on the next line.
      @synced_output = nil
      @flush_after_write = false
      # The local render is one unit: concurrent requests and worker threads
      # must not interleave lines. The transport hand-off runs outside this
      # lock — a hand-off waiting on the database must not freeze every logger
      # in the process.
      @write_lock = Mutex.new
    end

    # the minimum severity written, as a Symbol. Without an explicit level it
    # follows the mode (development `:debug`, every other mode `:info`), so an
    # in-process `Snails.env=` still moves it.
    #
    # @return [Symbol] one of `:debug`, `:info`, `:warn`, `:error`, `:fatal`
    def level
      return @level unless @level.nil?

      Snails.env.development? ? :debug : :info
    end

    # pin the level, overriding the mode's default.
    #
    # @param name [Symbol] one of `:debug`, `:info`, `:warn`, `:error`, `:fatal`
    # @raise [ArgumentError] name is not a known severity
    # @return [Symbol] the assigned level
    def level=(name)
      severity_rank(name)
      @level = name
      name
    end

    # whether a line at this severity would be written now.
    #
    # @return [Boolean]
    def debug?
      writes?(:debug)
    end

    # whether an info line would be written now.
    #
    # @return [Boolean] see `debug?`
    def info?
      writes?(:info)
    end

    # whether a warning line would be written now.
    #
    # @return [Boolean] see `debug?`
    def warn?
      writes?(:warn)
    end

    # whether an error line would be written now.
    #
    # @return [Boolean] see `debug?`
    def error?
      writes?(:error)
    end

    # whether a fatal line would be written now.
    #
    # @return [Boolean] see `debug?`
    def fatal?
      writes?(:fatal)
    end

    # the IO log lines are written to. An unset output answers `$stderr` at
    # write time, so an in-process redirection still applies.
    #
    # @return [IO] the current destination
    def output
      @output.nil? ? $stderr : @output
    end

    # send log lines somewhere else. A String path is rejected: open the file
    # first and pass the IO, or the typo would silently log nowhere. An IO that
    # answers `sync=` is put in sync mode on first write, so a line reaches its
    # destination from the write itself and the logger never flushes per line.
    #
    # @param io [IO, nil] an object answering `write`; nil restores stderr
    # @raise [ArgumentError] io is neither nil nor IO-like
    # @return [IO, nil] the assigned output
    def output=(io)
      if !io.nil? && !io.respond_to?(:write)
        raise ArgumentError, "Snails.logger.output expects an object answering write (an IO), got " + io.class.name
      end

      @output = io
      @synced_output = nil
      io
    end

    # the object that renders the five string calls.
    #
    # @return [untyped] the current formatter
    def formatter
      @formatter
    end

    # replace the rendering for string calls. The contract is
    # `call(severity, time, progname, message) -> String`; the returned string
    # is written as-is, so it must end with a newline. Structured records use
    # `record_formatter` instead.
    #
    # @param value [untyped] an object answering `call`
    # @raise [ArgumentError] value does not answer `call`
    # @return [untyped] the assigned formatter
    def formatter=(value)
      if !value.respond_to?(:call)
        raise ArgumentError, "Snails.logger.formatter expects an object answering call, got " + value.class.name
      end

      @formatter = value
      value
    end

    # the object that renders level calls carrying an `event:` name.
    #
    # @return [untyped] the current record formatter
    def record_formatter
      @record_formatter
    end

    # replace the rendering for structured records. The contract is
    # `call(record, progname) -> String`; the returned string is written as-is,
    # so it must end with a newline. Level calls without an `event:` name still
    # use `formatter`.
    #
    # @param value [untyped] an object answering `call`
    # @raise [ArgumentError] value does not answer `call`
    # @return [untyped] the assigned record formatter
    def record_formatter=(value)
      if !value.respond_to?(:call)
        raise ArgumentError, "Snails.logger.record_formatter expects an object answering call, got " + value.class.name
      end

      @record_formatter = value
      value
    end

    # the object that receives structured records, or nil when the logger only
    # writes locally. The slot is owned by `Snails::Logger::Delivery`, which
    # also isolates a unit delivery failure.
    #
    # @return [untyped] the current transport
    def transport
      @delivery.transport
    end

    # replace the record destination. The contract is `deliver(records)` with an
    # Array of `Record`; nil disables remote delivery. A unit delivery failure
    # is reported locally and does not stop the app; control and fatal
    # exceptions still propagate. Validation and the hand-off live in
    # `Delivery`.
    #
    # @param value [untyped] an object answering `deliver`, or nil
    # @raise [ArgumentError] value is neither nil nor transport-like
    # @return [untyped] the assigned transport
    def transport=(value)
      @delivery.transport = value
    end

    # the service name between `--` and `:` in the default line. Empty by
    # default; an app sharing a log stream with other processes sets its own.
    #
    # @return [String] the current progname
    def progname
      @progname
    end

    # set the service name rendered by the default formatter.
    #
    # @param name [String] the service name
    # @raise [ArgumentError] name is not a String
    # @return [String] the assigned name
    def progname=(name)
      if !name.is_a?(String)
        raise ArgumentError, "Snails.logger.progname expects a String, got " + name.class.name
      end

      @progname = name
    end

    # the host that names the process in resource attributes. An unset slot
    # answers `ENV["HOSTNAME"]` at read time, so a deployment can set the
    # environment variable without touching the app config.
    #
    # @return [String] the configured host name, possibly empty
    def host_name
      return @host_name unless @host_name.nil?

      ENV["HOSTNAME"].to_s
    end

    # set the host that every record's resource carries. An empty string omits
    # the attribute rather than sending an empty host.
    #
    # @param name [String] the host name
    # @raise [ArgumentError] name is not a String
    # @return [String] the assigned name
    def host_name=(name)
      if !name.is_a?(String)
        raise ArgumentError, "Snails.logger.host_name expects a String, got " + name.class.name
      end

      @host_name = name
    end

    # make this process's logger its own: a forked child may have inherited a
    # write lock another thread held, and the parent's buffered records would
    # otherwise be sent by every child. The prefork servers call it as the
    # child's first statement, before the first record; a process that never
    # forked has nothing to reset.
    #
    # @return [void]
    def after_fork
      # No thread is writing yet at this point, so replacing the lock is safe.
      @write_lock = Mutex.new
      @delivery.after_fork
    end

    # put the periodic buffer flush on the scheduler this process is about to
    # run. `ActiveJob::Launcher.start` calls it once per server process before
    # it spawns the loops; a second call in the same process does nothing.
    #
    # @return [void]
    def register_flush
      @delivery.register_flush
    end

    # hand every buffered record to the transport now. The periodic scheduler
    # calls it; a process shutting down can call it too. A non-fatal delivery
    # outcome is written locally; the caller cannot act on it. Callers here hold
    # no write lock, so the line goes through `report_local`, which takes it.
    #
    # @return [void]
    def flush
      report_outcome(@delivery.flush)
    end

    # write one line locally without creating a record or calling the transport.
    # The transport and its delivery job use it for their own failures, so a
    # broken destination cannot make logging recurse into itself.
    #
    # @param severity [Symbol] one of `:debug`, `:info`, `:warn`, `:error`, `:fatal`
    # @param message [untyped] rendered with `to_s`
    # @raise [ArgumentError] severity is not a known severity
    # @return [void]
    def report_local(severity, message)
      severity_rank(severity)
      @write_lock.synchronize { write_local_line(severity, message.to_s) }
    end

    # write at DEBUG when the level allows it. Without `event:` the call is a
    # plain line; with `event:` it is a named record.
    #
    # @param message [untyped] rendered with `to_s`
    # @param event [String, nil] the stable event name, e.g. `request.completed`
    # @param fields [Hash{String, Symbol => Object}] simple field values
    # @param exception [Exception, nil] the failure this event reports
    # @raise [ArgumentError] fields or an exception without an event name
    # @return [void]
    def debug(message, event: nil, fields: {}, exception: nil)
      write_level(:debug, message, event, fields, exception)
    end

    # write at INFO when the level allows it. Without `event:` the call is a
    # plain line; with `event:` it is a named record.
    #
    # @param message [untyped] rendered with `to_s`
    # @param event [String, nil] the stable event name, e.g. `request.completed`
    # @param fields [Hash{String, Symbol => Object}] simple field values
    # @param exception [Exception, nil] the failure this event reports
    # @raise [ArgumentError] fields or an exception without an event name
    # @return [void]
    def info(message, event: nil, fields: {}, exception: nil)
      write_level(:info, message, event, fields, exception)
    end

    # write at WARN when the level allows it. Without `event:` the call is a
    # plain line; with `event:` it is a named record.
    #
    # @param message [untyped] rendered with `to_s`
    # @param event [String, nil] the stable event name, e.g. `request.completed`
    # @param fields [Hash{String, Symbol => Object}] simple field values
    # @param exception [Exception, nil] the failure this event reports
    # @raise [ArgumentError] fields or an exception without an event name
    # @return [void]
    def warn(message, event: nil, fields: {}, exception: nil)
      write_level(:warn, message, event, fields, exception)
    end

    # write at ERROR when the level allows it. Without `event:` the call is a
    # plain line; with `event:` it is a named record.
    #
    # @param message [untyped] rendered with `to_s`
    # @param event [String, nil] the stable event name, e.g. `job.failed`
    # @param fields [Hash{String, Symbol => Object}] simple field values
    # @param exception [Exception, nil] the failure this event reports
    # @raise [ArgumentError] fields or an exception without an event name
    # @return [void]
    def error(message, event: nil, fields: {}, exception: nil)
      write_level(:error, message, event, fields, exception)
    end

    # write at FATAL when the level allows it. Without `event:` the call is a
    # plain line; with `event:` it is a named record.
    #
    # @param message [untyped] rendered with `to_s`
    # @param event [String, nil] the stable event name, e.g. `job.failed`
    # @param fields [Hash{String, Symbol => Object}] simple field values
    # @param exception [Exception, nil] the failure this event reports
    # @raise [ArgumentError] fields or an exception without an event name
    # @return [void]
    def fatal(message, event: nil, fields: {}, exception: nil)
      write_level(:fatal, message, event, fields, exception)
    end

    # The rank orders severities so the gate is one comparison: a line is
    # written when its rank is at or above the level's.
    def severity_rank(severity)
      case severity
      when :debug then 0
      when :info then 1
      when :warn then 2
      when :error then 3
      when :fatal then 4
      else
        raise ArgumentError, "Snails.logger.level expects one of :debug, :info, :warn, :error, :fatal, got " + severity.to_s
      end
    end

    def writes?(severity)
      severity_rank(severity) >= severity_rank(level)
    end

    # The one write path the five level methods share. A call without an
    # event name is a plain line plus an `app.log` record; a call with one is
    # a named record. `fields:` and `exception:` describe a named event, so
    # supplying them without `event:` raises instead of silently falling
    # back to `app.log` — the caller's intent would be lost in a record the
    # destination cannot filter by. The check runs before the level gate so
    # the mistake surfaces in every mode.
    def write_level(severity, message, event, fields, exception)
      if event.nil?
        if !fields.is_a?(Hash)
          raise ArgumentError, "Snails.logger." + severity.to_s + " fields expects a Hash, got " + fields.class.name
        end
        if !fields.empty? || !exception.nil?
          raise ArgumentError, "Snails.logger." + severity.to_s + " expects event: when fields: or exception: is given"
        end
        return unless writes?(severity)

        write_line(severity, message)
        return
      end

      write_event(severity, event, message.to_s, fields, exception)
    end

    # One named record at the level's severity. The call's shape is checked
    # before the level gate, so a malformed call raises in every mode; the
    # record itself is built only after the gate opens, so a dropped event
    # pays no field copies, context lookups, or clock read. An info event is
    # dropped when the app set `level = :warn`. The record carries the request
    # id, matched controller/action, and job context as reserved fields; the
    # service/process attributes ride separately in `Record#resource`. A
    # caller field with a reserved name raises rather than overwriting it.
    def write_event(severity, event, body, fields, exception)
      Record.validate_arguments(severity, event, body, exception)
      return unless writes?(severity)

      # The record writer is the one place that sees both the event name and
      # the running job, so it is where a job whose own records would feed the
      # pipeline it logs to (the log delivery job) has its `job.*` events
      # dropped. The queue therefore writes its lifecycle events
      # unconditionally and needs no per-job switch.
      return if event.start_with?("job.") && Context.job_events_suppressed?

      write_record(Record.new(
        severity, event, body,
        fields: fields, exception: exception,
        context: context_fields, resource: resource_fields
      ))
    end

    # A string call renders through the legacy formatter (so an app's
    # replacement keeps working) and still becomes an `app.log` record for
    # the transport. Rendering happens before the lock; the lock covers only
    # the write, so a line being formatted does not hold up other threads.
    # The record reaches the transport after the lock is released, so a
    # transport waiting on the database never holds up other threads' logging.
    def write_line(severity, message)
      body = message.to_s
      line = @formatter.call(severity.to_s.upcase, Time.now, @progname, tagged_message(body))
      write_output(line)
      deliver(Record.new(severity, "app.log", body, context: context_fields, resource: resource_fields))
    end

    # A structured event renders through the record formatter and then
    # reaches the transport, under the same split: the line under the lock,
    # the hand-off outside it.
    def write_record(record)
      write_output(@record_formatter.call(record, @progname))
      deliver(record)
    end

    # The one local write. A line is one `write` call under the lock, which is
    # what keeps concurrent lines whole. An output that answers `sync=` is
    # switched to sync mode once here, so the write itself reaches the
    # destination and no line pays a flush. An output without `sync=` (a custom
    # sink, a StringIO) keeps the explicit flush it has always had.
    def write_output(line)
      @write_lock.synchronize do
        io = output
        prepare_output(io)
        io.write(line)
        io.flush if @flush_after_write
      end
    end

    # Decide once per output how a line reaches the destination: a stream that
    # answers `sync=` is put in sync mode, so the write is not buffered; any
    # other output is flushed after each line, as before. Called with
    # `@write_lock` held.
    def prepare_output(io)
      return if @synced_output.equal?(io)

      @synced_output = io
      @flush_after_write = !io.respond_to?(:sync=)
      io.sync = true if !@flush_after_write
    end

    # `Delivery` owns the transport and the hand-off. The logger only turns a
    # returned non-fatal outcome into its local line, so the external side can
    # gain buffering and retries without changing this class. Called with no
    # write lock held: the transport may wait on the database, and that wait
    # must not hold up other threads' logging.
    def deliver(record)
      report_outcome(@delivery.deliver(record))
    end

    # One local line for a delivery outcome, and nothing for nil. The line is
    # written here rather than inside `Delivery` because it must never go back
    # through the transport — a failing sink would feed itself. Severity and
    # wording belong to the outcome, which `Delivery` owns.
    def report_outcome(outcome)
      report_local(outcome.severity, "[logger] " + outcome.message) unless outcome.nil?
    end

    # The local line writer assumes the caller holds `@write_lock`.
    def write_local_line(severity, message)
      line = @formatter.call(severity.to_s.upcase, Time.now, @progname, tagged_message(message))
      io = output
      prepare_output(io)
      io.write(line)
      io.flush if @flush_after_write
    end

    # `snails.request_id`, `snails.controller`, `snails.action`, and the job
    # values when a request or job is being served. They are reserved so a
    # caller cannot overwrite them.
    def context_fields
      fields = {}
      request_id = Context.request_id
      fields["snails.request_id"] = request_id if !request_id.nil? && !request_id.empty?
      controller = Context.controller
      fields["snails.controller"] = controller if !controller.nil? && !controller.empty?
      action = Context.action
      fields["snails.action"] = action if !action.nil? && !action.empty?
      job_name = Context.job_name
      fields["snails.job.name"] = job_name if !job_name.nil? && !job_name.empty?
      job_id = Context.job_id
      fields["snails.job.id"] = job_id unless job_id.nil?
      attempt = Context.job_attempt
      fields["snails.job.attempt"] = attempt unless attempt.nil?
      fields
    end

    # The service/process attributes every record carries. The local formatter
    # ignores them; a transport sends them once per batch. `host.name` comes
    # from the deployment environment and is omitted when unset.
    def resource_fields
      fields = {}
      fields["service.name"] = Snails.app.app_name
      host = host_name
      fields["host.name"] = host if !host.nil? && !host.empty?
      fields["process.pid"] = Process.pid
      fields["deployment.environment.name"] = Snails.env.name
      fields["snails.version"] = Snails.version
      fields["snails.rev"] = Snails.rev
      fields["snails.log.schema_version"] = Record::SCHEMA_VERSION
      fields
    end

    # The request id rides in the message rather than in the formatter: a
    # replacement formatter (a JSON line, say) receives the same tag
    # without implementing the request context itself. It is spelled as a
    # key=value field so a request line underneath it stays parseable as
    # one `request_id=… key=value …` record.
    def tagged_message(message)
      id = Context.request_id
      return message.to_s if id.nil? || id.empty?

      "request_id=" + id + " " + message.to_s
    end

    private :severity_rank, :writes?, :write_level, :write_event,
            :write_line, :write_record, :write_output, :prepare_output, :deliver,
            :report_outcome, :write_local_line,
            :context_fields, :resource_fields, :tagged_message
  end
end
