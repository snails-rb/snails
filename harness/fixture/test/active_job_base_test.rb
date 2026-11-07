require_relative "test_helper"
require_relative "harness_runner"

# A bare job: the key derives from the class name, only the body is
# declared.
class DerivedNameJob < ActiveJob::Base
  def self.perform(data)
  end
end

# A job that overrides the derived key.
class OverrideNameJob < ActiveJob::Base
  def self.job_name = "custom-key"

  def self.perform(data)
  end
end

# A job with neither declaration: the name derives and the body spec
# raises.
class NoBodyJob < ActiveJob::Base
end

# A named job with an observable body — the stored-name cases drive
# it through the dynamic lookup.
class NamedJob < ActiveJob::Base
  def self.perform(data)
    JobBaseSink::RAN << 1
  end
end

# A payload job: the arguments ride the payload and arrive as
# `perform`'s `data` argument.
class ArgumentJob < ActiveJob::Base
  def self.perform(data)
    JobBaseSink::RAN << data["id"]
  end
end

# A job whose body returns a non-nil value — `perform` is `void`, so the
# value is discarded by every dispatch path.
class ValueReturningJob < ActiveJob::Base
  def self.perform(data)
    JobBaseSink::RAN << 1
    42
  end
end

class JobBaseSink
  RAN = []
end

# ActiveJob::Base (core) — the job contract: `job_name` is implemented on
# the base (the class name, overridable) and `perform(data)` is a
# raising spec taking the decoded payload (nil when none — the base
# refuses without an override). The module entry that reads the contract
# (`enqueue`'s payload path) and the store-backed resolution convention
# (`Object.const_get` → `perform` — the adapter owns it) are driven here,
# so the cases prove the members through their consumers.
class JobBaseTest < TestBase
  def setup
    ActiveJob::EXECUTORS.clear
    ActiveJob::RECURRING.clear
    ActiveJob::Scheduler::PERIODIC.clear
    ActiveJob.queue_adapter = ActiveJob::ProcessQueue
    JobBaseSink::RAN.clear
  end

  def assert_equal(expected, actual, msg = nil)
    raise(msg || "expected #{expected.inspect}, got #{actual.inspect}") unless expected == actual
  end

  # The derived default: a job without a `job_name` declaration registers
  # under its class name — the key has one source, not two.
  def test_job_name_derives_from_the_class_name
    ActiveJob.recurring(DerivedNameJob, 300)
    assert_equal "DerivedNameJob", ActiveJob::RECURRING[0]["name"]
  end

  # Override: a job may register under a key that differs from its class
  # name by overriding the derived default.
  def test_job_name_override_keeps_the_declared_key
    ActiveJob.recurring(OverrideNameJob, 300)
    assert_equal "custom-key", ActiveJob::RECURRING[0]["name"]
  end

  # Missing body: registration succeeds (the name derives), and the
  # beat's fire raises the spec's message when it runs the job.
  def test_missing_perform_fails_loud
    ActiveJob.recurring(NoBodyJob, 300)
    begin
      ActiveJob::Scheduler::PERIODIC[0]["work"].call
    rescue NotImplementedError => e
      assert_equal "perform: subclasses must override", e.message
      return
    end
    raise "expected NotImplementedError from ActiveJob::Base#perform"
  end

  # The payload path at the call site: with no executor, `enqueue` runs
  # the job with the payload as `perform`'s argument, no per-job wrapper.
  def test_payload_enqueue_passes_the_payload_to_the_body
    ActiveJob.enqueue(ArgumentJob, { "id" => 7 })
    assert_equal [ 7 ], JobBaseSink::RAN
  end

  # The body's result is not used: `perform` is void, so a non-nil return
  # is allowed and discarded by the call-site path.
  def test_perform_result_is_discarded
    ActiveJob.enqueue(ValueReturningJob)
    assert_equal [ 1 ], JobBaseSink::RAN
  end

  # The store-backed convention: a stored name is a constant path and the
  # resolution runs through `Object.const_get` — the adapter owns it (the
  # runtime offers no helper).
  def test_a_stored_name_resolves_to_its_class_and_runs
    job_class = Object.const_get("NamedJob")
    job_class.perform(nil)
    assert_equal [ 1 ], JobBaseSink::RAN
  end

  # The same convention with a payload: the decoded data reaches the
  # job's `perform` as its argument.
  def test_a_stored_name_with_a_payload_runs_the_body
    job_class = Object.const_get("ArgumentJob")
    job_class.perform({ "id" => 5 })
    assert_equal [ 5 ], JobBaseSink::RAN
  end

  # Unknown name: the dynamic lookup fails loud at run time with the
  # runtime's own message (a store-backed adapter surfaces it as the
  # job's failure).
  def test_an_unknown_stored_name_fails_loud
    begin
      Object.const_get("GhostJob")
    rescue NameError => e
      assert_equal "uninitialized constant GhostJob", e.message
      return
    end
    raise "expected NameError from the stored-name lookup"
  end

  # A schedule needs a real run time: with Time active (the ext layer
  # reopens it) the Time-typed slot refuses a non-Time at the boundary —
  # an untyped value never reaches the body, and a known-type non-Time
  # does not even build.
  def test_schedule_rejects_a_non_time
    value = JSON.parse("1792175700")
    begin
      ActiveJob.schedule(NamedJob, value)
    rescue TypeError
      return
    end
    raise "expected TypeError from ActiveJob.schedule"
  end

  # With no executor a schedule raises instead of running now: the delay
  # is the point, and a queue nobody drains is a silent loss.
  def test_schedule_without_an_executor_raises
    begin
      ActiveJob.schedule(NamedJob, Time.now.utc + 900)
    rescue RuntimeError => e
      assert_equal "schedule needs an executor — a scheduled job with none would be silently lost", e.message
      return
    end
    raise "expected RuntimeError from ActiveJob.schedule"
  end
end

FixtureRunner.run(JobBaseTest, [
  "test_job_name_derives_from_the_class_name",
  "test_job_name_override_keeps_the_declared_key",
  "test_missing_perform_fails_loud",
  "test_payload_enqueue_passes_the_payload_to_the_body",
  "test_perform_result_is_discarded",
  "test_a_stored_name_resolves_to_its_class_and_runs",
  "test_a_stored_name_with_a_payload_runs_the_body",
  "test_an_unknown_stored_name_fails_loud",
  "test_schedule_rejects_a_non_time",
  "test_schedule_without_an_executor_raises"
])
