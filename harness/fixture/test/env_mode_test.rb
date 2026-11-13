require_relative "test_helper"
require_relative "harness_runner"

# SNAILS_ENV mode (core) — `Snails.env` reads ENV["SNAILS_ENV"] once and
# memoizes the predicates the logger's debug gate and app-side dev-only
# branches read. Development is the unset (or empty) default; a name
# outside the vocabulary returns false for every predicate rather than
# raising (mode is read on the request path). `Snails.env=` replaces the
# mode in-process, which these cases use instead of mutating ENV.
class EnvModeTest < TestBase
  def assert_equal(expected, actual)
    raise("expected #{expected.inspect}, got #{actual.inspect}") unless expected == actual
  end

  def test_mode_predicates
    prev = ENV["SNAILS_ENV"]

    Snails.env = "development"
    assert_equal true, Snails.env.development?
    assert_equal false, Snails.env.test?

    Snails.env = "test"
    assert_equal true, Snails.env.test?
    assert_equal false, Snails.env.development?

    Snails.env = "staging"
    assert_equal true, Snails.env.staging?
    assert_equal false, Snails.env.production?

    Snails.env = "production"
    assert_equal true, Snails.env.production?
    assert_equal false, Snails.env.development?

    Snails.env = nil
    assert_equal true, Snails.env.development?

    Snails.env = ""
    assert_equal true, Snails.env.development?

    Snails.env = "prod"
    assert_equal false, Snails.env.production?
    assert_equal false, Snails.env.development?

    Snails.env = prev
  end

  # The first read took the runner's SNAILS_ENV (scripts/test-runtime.sh
  # exports test, as an app's test.env does) and memoized it.
  def test_env_reads_snails_env
    assert_equal true, Snails.env.test?
  end
end

FixtureRunner.run(EnvModeTest, ["test_mode_predicates", "test_env_reads_snails_env"])
