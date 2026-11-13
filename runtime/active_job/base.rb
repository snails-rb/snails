# The job API: class-oriented enqueue and schedule, the adapter slot, and
# `recurring`. `perform` runs on the job class, never an instance; a stored
# name must resolve through `Object.const_get`. Adapter names must stay unique
# program-wide, and adapters must serialize their own mutable state.

module ActiveJob
  # the hand-off entry: the job class is the argument (its `job_name` keys the
  # entry) and the work derives from the class — one call form,
  # `perform(payload)`, so a payload-less job still declares the parameter and
  # ignores it.
  #
  # The proc is what keeps the process-local queue expressible on a
  # target with one element type per container — every entry is
  # `() -> void` whatever it closed over, so jobs of any arity share one
  # Array. The selected adapter takes it from here: `ProcessQueue` keeps
  # the proc; a store-backed adapter stores the name and payload and
  # ignores the proc; the drain resolves them itself (`Object.const_get`).
  # With an executor registered the work is queued and this returns
  # immediately; with none it runs at the call site. A bounded adapter may
  # refuse the hand-off when its queue is full (the process queue drops the
  # new job and reports locally) — a request path must not assume every
  # hand-off became queued work.
  #
  # @param job_class [Class] the job class — `job_name` + `perform(data)`
  # @param payload [Object, nil] the serializable arguments for a
  #   serializing adapter — a JSON value, or nil for a payload-less job
  # @return [void]
  # @example
  #   class NotifyJob < ActiveJob::Base
  #     def self.perform(data)
  #       id = data["id"]
  #       ...
  #     end
  #   end
  #
  #   ActiveJob.enqueue(NotifyJob, { "id" => 42 })
  def self.enqueue(job_class, payload = nil)
    work = -> { job_class.perform(payload) }
    if executor_registered
      queue_adapter.enqueue(job_class.job_name, work, payload)
    else
      work.call
    end
  end

  # hand off a delayed one-off run: the same class-oriented hand-off as
  # `enqueue`, but the work waits until `at` (`Time`) instead of running at the
  # next drain. The adapter stores the run time (`enqueue_at`), and a drain runs
  # the job once the clock passes it. With no executor registered this raises: a
  # schedule needs one, and running it at the call site would ignore the delay —
  # the same silent-loss rule `enqueue` follows, kept strict here.
  #
  # `at` carries its own contract: the Time slot refuses a non-Time
  # argument at the build or the call boundary (the ext layer reopens
  # Time — ext/time.rb), so no in-body guard stands here.
  #
  # @param job_class [Class] the job class — `job_name` + `perform(data)`
  # @param at [Time] the run time
  # @param payload [Object, nil] the serializable arguments for a
  #   serializing adapter — a JSON value, or nil for a payload-less job
  # @return [void]
  # @raise [RuntimeError] no executor is registered — a schedule needs one
  # @example
  #   ActiveJob.schedule(NotifyJob, Time.now + 900, { "id" => 42 })
  def self.schedule(job_class, at, payload = nil)
    if executor_registered
      queue_adapter.enqueue_at(job_class.job_name, -> { job_class.perform(payload) }, payload, at)
    else
      raise "schedule needs an executor — a scheduled job with none would be silently lost"
    end
  end

  # The adapter slot: the selected adapter class, empty for the default
  # (`ProcessQueue`). The app selects one at boot, before the server starts,
  # with `queue_adapter=` — any class carrying the adapter interface (the file
  # header).
  QUEUE_ADAPTER = []

  # the adapter class every hand-off and drain goes through: the selected one,
  # or `ProcessQueue` when none was selected.
  #
  # @return [Class] the selected adapter class
  def self.queue_adapter
    if QUEUE_ADAPTER.empty?
      ProcessQueue
    else
      QUEUE_ADAPTER[0]
    end
  end

  # select a queue adapter. Any class is taken: the interface is the contract
  # (see the file header), and the setter's job is the swap, not a registry — an
  # allowlist would turn every new adapter into a core change. A typo'd constant
  # fails at compile/load; a class missing the interface raises at its first
  # dispatch.
  #
  # @param adapter [Class] an adapter class — `ProcessQueue` or an app's own
  # @return [void]
  def self.queue_adapter=(adapter)
    QUEUE_ADAPTER.clear
    QUEUE_ADAPTER << adapter
  end

  # The executor registry: one entry per registration — the array's
  # length is the whole "an executor exists in this process" flag
  # `executor_registered` reads.
  EXECUTORS = []

  # whether an executor exists in this process: `enqueue` queues only while this
  # answers true and runs the job at the call site otherwise, because a job
  # nobody drains would be silently lost.
  #
  # @return [Boolean] true when an executor is registered
  def self.executor_registered
    EXECUTORS.length > 0
  end

  # declare that an executor exists in this process; `enqueue` queues only after
  # this. `Snails::Main.start` calls it once at boot, so the switch is one-way:
  # there is no unregister.
  #
  # @return [void]
  def self.register_executor
    EXECUTORS << "1"
  end

  # The recurring registrations, one Hash per entry (the `PERIODIC` shape) —
  # `recurring` appends here and the wired beat carries the entry, so the
  # registry is what boot-time introspection and the contract tests read.
  RECURRING = []

  # one call declares a job that runs once per `interval` seconds. The class
  # carries the job contract (`Base`) — `job_name` (the key) and a class-side
  # `perform` — and the registration wires the beat (the scheduler's periodic
  # registry; each fire enqueues once per interval — the interval's start
  # (`scheduled_at_for`) goes to `enqueue_once`, where a second enqueue for the
  # same (name, scheduled_at) must be a no-op, so several server processes
  # firing the same beat still run the job once). There is no handler catalog: a
  # cross-process drain resolves the stored name itself — `Object.const_get` —
  # so the registration's class is what must be compiled in. The beat's run proc
  # takes no argument (a process-local adapter runs it as the job). Call it
  # after the adapter is selected.
  #
  # @param job_class [Class] the job class — `job_name` + class-side `perform`
  # @param interval [Integer] seconds between runs
  # @return [void]
  # @example
  #   ActiveJob.recurring(CleanupJob, 300)
  def self.recurring(job_class, interval)
    name = job_class.job_name
    entry = { "name" => name, "interval" => interval, "work" => -> { job_class.perform(nil) } }
    # Register the beat first: a rejected interval (register_periodic
    # validates) must not leave a half-registered RECURRING entry.
    Scheduler.register_periodic(interval, -> { enqueue_recurring(entry) })
    RECURRING << entry
  end

  # the run key a recurring fire enqueues with: the interval's start (`now`
  # floored to the interval) as a Time, so every process firing inside the same
  # interval computes the same value and the adapter's unique key drops the
  # repeats.
  #
  # @param interval [Integer] seconds per interval
  # @param now [Time] the clock to floor
  # @return [Time] the interval's start
  def self.scheduled_at_for(interval, now = Time.now.utc)
    stamp = now.to_i
    Time.at(stamp - (stamp % interval)).utc
  end

  # one fire of a recurring job: with an executor registered the enqueue goes
  # through the adapter once per interval (`enqueue_once` with the interval's
  # start from `scheduled_at_for`); with none the body runs at the call site,
  # the `enqueue` rule (a queue nobody drains is a silent loss). `now` is
  # injectable so the contract is testable without sleeping.
  #
  # Private on purpose: `recurring` is the public declaration; this fire
  # helper is free to change without notice.
  def self.enqueue_recurring(entry, now = Time.now.utc)
    if executor_registered
      queue_adapter.enqueue_once(entry["name"], entry["work"], nil, scheduled_at_for(entry["interval"], now))
    else
      entry["work"].call
    end
  end

  private_class_method :enqueue_recurring

  # The job class contract — the members every dispatch path reads: `recurring`
  # calls `job_name` to key the registration, the adapter's handler catalog is
  # keyed by the same name, and the body runs as `job_class.perform(data)` — a
  # class method; this runtime never instantiates a job. `data` is the decoded
  # payload (nil when none). The base implements `job_name` (the class name);
  # the method bodies stay raising stubs (the `Sqlx::Base` pattern). A job that
  # forgot a body raises with the contract named, wherever it was driven from.
  class Base
    # the key the job registers and is dispatched under: the recurring beat's
    # name, the adapter's handler catalog entry, and the name a store-backed
    # drain resolves back to the class all use it. The base derives it from the
    # class name (`name`); a job overrides this method when the key must differ
    # — for cross-process dispatch the key must stay a constant path
    # (`Object.const_get` resolves it on the store-backed drain).
    #
    # @return [String] the job's name — the class name by default; not
    #   input, and not validated: a name no constant carries is a lookup
    #   miss at dispatch
    # @example derived — the class name is the key, nothing to declare
    #   class CleanupJob < ActiveJob::Base
    #   end
    # @example override — the key differs from the class name
    #   def self.job_name = "nightly-cleanup"
    def self.job_name
      name
    end

    # the job body, a class method: every runtime-driven path calls it with one
    # argument — `data` is the decoded payload, nil for a payload-less job — so
    # one call shape covers both (`recurring`'s beat, `enqueue`, a store-backed
    # drain); a job that takes no arguments still declares the parameter and
    # ignores it. The runtime never instantiates a job. The base raises so a job
    # that forgot the body raises with the contract named instead of a bare
    # `NoMethodError` at its first fire.
    #
    # @param data [Object, nil] the decoded payload, nil for a payload-less job
    # @return [void] the body's result is not used
    # @raise [NotImplementedError] on the base — the subclass has not
    #   overridden it
    # @example
    #   def self.perform(data)
    #     Cleanup.run_once
    #   end
    def self.perform(data)
      raise NotImplementedError, "perform: subclasses must override"
    end
  end
end
