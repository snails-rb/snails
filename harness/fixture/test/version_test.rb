require_relative "test_helper"
require_relative "harness_runner"

# Snails version metadata (core) — the framework identity and the app-owned
# version/revision readers. The framework constants are stamped into the dist
# artifact; the app readers exist on `Snails::Application` and may be reopened.
class VersionTest < TestBase
  # A subclass stands in for an app reopen: the default readers are inherited
  # and the app can replace either one.
  class VersionedApplication < Snails::Application
    def version
      "app-version"
    end

    def revision
      "app-revision"
    end
  end

  def assert_equal(expected, actual)
    raise("expected #{expected.inspect}, got #{actual.inspect}") unless expected == actual
  end

  # The framework version reads the constant baked in by dist publish.
  def test_snails_version_reads_the_constant
    assert_equal Snails::VERSION, Snails.version
    assert_equal true, !Snails.version.empty?
  end

  # The framework rev reads the same constant.
  def test_snails_rev_reads_the_constant
    assert_equal Snails::REV, Snails.rev
    assert_equal true, !Snails.rev.empty?
  end

  # The app version has no default — an app that does not declare one
  # returns nil.
  def test_app_version_defaults_to_nil
    assert_equal nil, Snails::Application.new.version
  end

  # An app override wins — the app owns its version and revision.
  def test_app_readers_can_be_overridden
    app = VersionedApplication.new
    assert_equal "app-version", app.version
    assert_equal "app-revision", app.revision
  end

  # App revision reads ENV["REVISION"] first.
  def test_app_revision_reads_env
    previous = ENV["REVISION"]
    ENV["REVISION"] = "env-revision"
    begin
      assert_equal "env-revision", Snails::Application.new.revision
    ensure
      ENV["REVISION"] = previous
    end
  end

  # Without ENV, app revision reads the REVISION file at the app root.
  def test_app_revision_reads_the_revision_file
    previous = ENV["REVISION"]
    ENV["REVISION"] = nil
    File.open("REVISION", "w") { |file| file.write("file-revision\n") }
    begin
      assert_equal "file-revision", Snails::Application.new.revision
    ensure
      File.delete("REVISION") if File.exist?("REVISION")
      ENV["REVISION"] = previous
    end
  end

  # Revision is a deployment identifier, so it is fixed after the first read —
  # it does not change like a request value.
  def test_app_revision_is_memoized
    previous = ENV["REVISION"]
    ENV["REVISION"] = "first-revision"
    begin
      app = Snails::Application.new
      assert_equal "first-revision", app.revision
      ENV["REVISION"] = "second-revision"
      assert_equal "first-revision", app.revision
    ensure
      ENV["REVISION"] = previous
    end
  end
end

FixtureRunner.run(VersionTest, [
  "test_snails_version_reads_the_constant",
  "test_snails_rev_reads_the_constant",
  "test_app_version_defaults_to_nil",
  "test_app_readers_can_be_overridden",
  "test_app_revision_reads_env",
  "test_app_revision_reads_the_revision_file",
  "test_app_revision_is_memoized"
])
