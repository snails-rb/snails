require_relative "test_helper"
require_relative "harness_runner"

# ActiveJob::Launcher (core) — the worker-thread count reader. `start` is
# the server entry; the count is also public because `process.started`
# reports it. The launcher itself is a thread spawner that the servers call
# once per server process, so only the count contract runs here.
class JobLauncherTest < TestBase
  def setup
    ENV["WORKER_CONCURRENCY"] = ""
  end

  def assert_equal(expected, actual, msg = nil)
    raise(msg || "expected #{expected.inspect}, got #{actual.inspect}") unless expected == actual
  end

  # The count reader is public: process metadata reports the effective value.
  def test_concurrency_is_public
    assert_equal 1, ActiveJob::Launcher.concurrency
  end

  # The count comes from the env — one unless the app opts in.
  def test_concurrency_defaults_to_one
    assert_equal 1, ActiveJob::Launcher.concurrency
  end

  def test_concurrency_reads_the_env
    ENV["WORKER_CONCURRENCY"] = "3"
    assert_equal 3, ActiveJob::Launcher.concurrency
  end

  # A bad value fails at boot instead of silently running one worker thread: zero,
  # a non-number, and numbers with trailing garbage all raise.
  def test_concurrency_rejects_a_bad_env
    [ "0", "abc", "1abc", "3.5" ].each do |value|
      ENV["WORKER_CONCURRENCY"] = value
      bad = false
      begin
        ActiveJob::Launcher.concurrency
      rescue ArgumentError
        bad = true
      end
      assert_equal true, bad
    end
  end
end

FixtureRunner.run(JobLauncherTest, [
  "test_concurrency_is_public",
  "test_concurrency_defaults_to_one",
  "test_concurrency_reads_the_env",
  "test_concurrency_rejects_a_bad_env"
])
