require_relative "test_helper"
require_relative "harness_runner"

# `Snails.app.secret_key_base` (core) — the standard signing-key reader.
# The source is SECRET_KEY_BASE, read at call time; a missing or empty value
# raises instead of answering "" (an empty key signs for anyone).
class SecretKeyBaseTest < TestBase
  def assert_equal(expected, actual, msg = nil)
    raise(msg || "expected #{expected.inspect}, got #{actual.inspect}") unless expected == actual
  end

  # The reader refuses a missing key rather than answering an empty one.
  # The case clears the variable first so a shell value cannot mask the
  # contract.
  def test_missing_key_raises
    ENV["SECRET_KEY_BASE"] = nil
    raised = false
    begin
      Snails.app.secret_key_base
    rescue ArgumentError => e
      raised = true
      assert_equal true, e.message.include?("SECRET_KEY_BASE")
    end
    assert_equal true, raised
  end

  # The environment value is the standard source, and repeated reads answer
  # the same value.
  def test_reads_the_environment_value
    ENV["SECRET_KEY_BASE"] = "harness-signing-key"
    assert_equal "harness-signing-key", Snails.app.secret_key_base
    assert_equal "harness-signing-key", Snails.app.secret_key_base
  end

  # An empty value is as unusable as a missing one — it is a guessable key.
  def test_empty_key_raises
    ENV["SECRET_KEY_BASE"] = ""
    raised = false
    begin
      Snails.app.secret_key_base
    rescue ArgumentError => e
      raised = true
      assert_equal true, e.message.include?("SECRET_KEY_BASE")
    end
    assert_equal true, raised
  end
end

FixtureRunner.run(SecretKeyBaseTest, [
  "test_missing_key_raises",
  "test_reads_the_environment_value",
  "test_empty_key_raises"
])
