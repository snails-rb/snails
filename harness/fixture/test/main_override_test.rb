require_relative "test_helper"
require_relative "harness_runner"

# Reopen-order/override rule — the fixture's config/environment.rb is
# loaded by boot's LAST require (the way an app carries it)
# AFTER the core defaults in snails-core/snails/main.rb, so its definition must run
# instead of the core one. If a spinel change flips the last-load-wins
# rule, this fails instead of silently running the core default in
# production.
class MainOverrideTest < TestBase
  def assert_equal(expected, actual)
    raise("expected #{expected.inspect}, got #{actual.inspect}") unless expected == actual
  end

  def test_app_override_wins
    assert_equal "app:configure_database!", Snails::Main.configure_database!
  end

  # The override shadows only its own name — an untouched core default
  # keeps working next to it.
  def test_untouched_core_default_stays
    rows = Snails::Main.route_table
    assert_equal 8, rows.length
    assert_equal "/up", rows[0].pattern
  end
end

FixtureRunner.run(MainOverrideTest, [
  "test_app_override_wins",
  "test_untouched_core_default_stays",
])
