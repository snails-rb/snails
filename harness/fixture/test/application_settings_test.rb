require_relative "test_helper"
require_relative "harness_runner"

# `Snails.app` (core) — the app-facing read channel. The fixture's
# config/application.rb reopens Snails::Application for app_name; these cases
# pin the stable instance and the values the runtime reads.
class ApplicationSettingsTest < TestBase
  def assert_equal(expected, actual)
    raise("expected #{expected.inspect}, got #{actual.inspect}") unless expected == actual
  end

  # The settings object is one instance — a per-call object would break the
  # cache identity and the slots the environment file writes.
  def test_application_is_one_stable_object
    assert_equal true, Snails.app.equal?(Snails.app)
  end

  # The app reopen supplies app_name; time_zone reads the process slot set in
  # config/environment.rb.
  def test_app_settings_read_from_their_owners
    assert_equal "UTC", Snails.app.time_zone
    assert_equal "harness", Snails.app.app_name
  end

  # The readers run without a request context — a request-derived value in the
  # channel would break here.
  def test_settings_read_without_a_request
    assert_equal true, ActionController::Current.request.nil?
    assert_equal "UTC", Snails.app.time_zone
    assert_equal "harness", Snails.app.app_name
  end

  # The old `config_time_zone` name is gone, not aliased — an app still
  # reading it fails instead of seeing two names for one slot.
  def test_legacy_config_time_zone_is_not_defined
    raise "expected Snails.app.config_time_zone to be removed" if Snails.app.respond_to?(:config_time_zone)
  end
end

FixtureRunner.run(ApplicationSettingsTest, [
  "test_application_is_one_stable_object",
  "test_app_settings_read_from_their_owners",
  "test_settings_read_without_a_request",
  "test_legacy_config_time_zone_is_not_defined"
])
