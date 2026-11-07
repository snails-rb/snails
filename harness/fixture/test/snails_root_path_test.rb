require_relative "test_helper"
require_relative "harness_runner"

# `Snails.root` (core) — the app root as a typed path value. The root is the
# process working directory ("."), and AppPath answers interpolation, join,
# +, and the implicit conversion File methods use.
class SnailsRootPathTest < TestBase
  def assert_equal(expected, actual)
    raise("expected #{expected.inspect}, got #{actual.inspect}") unless expected == actual
  end

  # The root is "." so interpolated paths stay byte-identical.
  def test_root_is_the_working_directory
    assert_equal ".", Snails.root.to_s
    assert_equal "./tmp", "#{Snails.root}/tmp"
  end

  # join appends each part with one separator; no parts answers the same path.
  def test_join_appends_parts
    assert_equal "./tmp/storage", Snails.root.join("tmp", "storage").to_s
    assert_equal "./tmp", Snails.root.join("tmp").to_s
    assert_equal ".", Snails.root.join.to_s
  end

  # + is a path join, not string concatenation.
  def test_plus_joins_a_path
    assert_equal "./storage", (Snails.root + "storage").to_s
  end

  # to_path is the implicit conversion File methods look for (cwd is the
  # harness dir, so test_helper.rb sits under the root).
  def test_to_path_is_accepted_by_file_methods
    assert_equal true, File.exist?(Snails.root.join("test", "test_helper.rb"))
  end
end

FixtureRunner.run(SnailsRootPathTest, [
  "test_root_is_the_working_directory",
  "test_join_appends_parts",
  "test_plus_joins_a_path",
  "test_to_path_is_accepted_by_file_methods"
])
