require_relative "test_helper"
require_relative "harness_runner"

# `Snails.time_zone` and `Snails.iana_zone` (core) — the process zone slot
# resolves a zone name or an IANA identifier, validates the zone file,
# and pins ENV["TZ"] for libc. The fixture's config/environment.rb writes the
# slot at boot; `Snails.app.time_zone` reads it back as an IANA identifier.
class TzMappingTest < TestBase
  def assert_equal(expected, actual, msg = nil)
    raise(msg || "expected #{expected.inspect}, got #{actual.inspect}") unless expected == actual
  end

  # Registered zone names translate to their IANA identifier —
  # including Seoul, which apps set as `Snails.time_zone`.
  def test_registered_names_map
    assert_equal "UTC", Snails.iana_zone("UTC")
    assert_equal "Asia/Seoul", Snails.iana_zone("Seoul")
    assert_equal "America/New_York", Snails.iana_zone("Eastern Time (US & Canada)")
    assert_equal "Asia/Tokyo", Snails.iana_zone("Tokyo")
  end

  # An unregistered name falls back to itself — a valid IANA identifier
  # with a zone file works as-is.
  def test_unregistered_passes_through
    assert_equal "Europe/Madrid", Snails.iana_zone("Europe/Madrid")
    assert_equal "America/Chicago", Snails.iana_zone("America/Chicago")
  end

  # A misspelled zone name matches no file, so the setter fails loud
  # rather than leaving the process in UTC.
  def test_unknown_name_raises
    begin
      Snails.iana_zone("Seuol")
    rescue ArgumentError
      return
    end
    raise "expected Snails.iana_zone to reject an unknown zone name"
  end

  # The same rule covers an IANA-shaped path with no zone file.
  def test_unknown_iana_path_raises
    begin
      Snails.iana_zone("Asia/Seuol")
    rescue ArgumentError
      return
    end
    raise "expected Snails.iana_zone to reject an unknown IANA identifier"
  end

  # The setter resolves a name, pins the process zone, and both readers see
  # the IANA identifier. Restore UTC so the rest of the suite runs in the
  # fixture's zone.
  def test_time_zone_setter_pins_process_and_readers
    Snails.time_zone = "Seoul"
    assert_equal "Asia/Seoul", Snails.time_zone
    assert_equal "Asia/Seoul", Snails.app.time_zone
    assert_equal "Asia/Seoul", ENV["TZ"]
    Snails.time_zone = "UTC"
  end

  # A rejected name changes neither the slot nor the process zone.
  def test_invalid_setter_leaves_the_zone_unchanged
    Snails.time_zone = "UTC"
    begin
      Snails.time_zone = "Seuol"
    rescue ArgumentError
      assert_equal "UTC", Snails.time_zone
      assert_equal "UTC", ENV["TZ"]
      return
    end
    raise "expected Snails.time_zone= to reject an unknown zone name"
  end

  # The boot line ran: the process zone carries the fixture's declared zone,
  # and the app reader sees the same value. The gate exports no TZ, so a
  # dropped line would leave this nil.
  def test_process_zone_pinned_at_boot
    assert_equal "UTC", ENV["TZ"]
    assert_equal "UTC", Snails.app.time_zone
  end
end

FixtureRunner.run(TzMappingTest, [
  "test_registered_names_map",
  "test_unregistered_passes_through",
  "test_unknown_name_raises",
  "test_unknown_iana_path_raises",
  "test_time_zone_setter_pins_process_and_readers",
  "test_invalid_setter_leaves_the_zone_unchanged",
  "test_process_zone_pinned_at_boot"
])
