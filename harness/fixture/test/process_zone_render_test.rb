require_relative "test_helper"
require_relative "harness_runner"
require_relative "test_database"

# The process zone is what renders local time — the app pins it once with
# `Snails.time_zone =` and everything local lands there: the clock, a stored
# UTC text read through a model, and the JSON spelling. The fixture boots in
# UTC, where a dropped `getlocal` or a UTC-only renderer reads as green (an
# instant compares equal either way), so these cases pin the same stored
# instant while the slot says Seoul.
class ProcessZoneRenderTest < TestBase
  # The model for the DB case: one declared datetime column, hydrated through
  # the core `from_row`.
  class ZoneStamp < Sqlx::Base
    %w[id at].each { |n| define_method(n) { read_attribute(n) } }

    def self.table_name = "zone_stamps"
    def self.only_columns = [:id, :at]
    def self.datetime_columns = %w[at]
  end

  # setup owns a fresh table per case.
  def setup
    TestDatabase.configure!("process_zone_render")
    TestDatabase.drop_tables!("zone_stamps")
    TestDatabase.exec("CREATE TABLE zone_stamps (id INTEGER PRIMARY KEY, at DATETIME)")
    TestDatabase.exec("INSERT INTO zone_stamps (id, at) VALUES (1, '2024-01-02 03:04:05.000006')")
  end

  def assert_equal(expected, actual, msg = nil)
    raise(msg || "expected #{expected.inspect}, got #{actual.inspect}") unless expected == actual
  end

  # The setter hands the zone to libc: the clock reads the pinned offset, not
  # the host's.
  def test_time_now_reads_the_pinned_offset
    Snails.time_zone = "Seoul"
    assert_equal 32400, Time.now.utc_offset
    Snails.time_zone = "UTC"
  end

  # A stored UTC text lands in the pinned zone (`String#to_time` ends with
  # `getlocal`): the instant survives and the wall clock is Seoul's.
  def test_stored_text_lands_in_the_pinned_zone
    Snails.time_zone = "Seoul"
    t = "2024-01-02 03:04:05.000006".to_time
    assert_equal Time.utc(2024, 1, 2, 3, 4, 5, 6), t
    assert_equal 32400, t.utc_offset
    Snails.time_zone = "UTC"
  end

  # The model read follows the same rule: `from_row` converts the declared
  # datetime column through the stored-time codec, so a row reads in the app's
  # zone, not in UTC.
  def test_model_datetime_read_lands_in_the_pinned_zone
    Snails.time_zone = "Seoul"
    rows = Sqlx::Base.rows_by_sql("SELECT id, at FROM zone_stamps WHERE id = ?", [1])
    stamp = ZoneStamp.from_row(rows[0])
    assert_equal Time.utc(2024, 1, 2, 3, 4, 5, 6), stamp.at
    assert_equal 32400, stamp.at.utc_offset
    Snails.time_zone = "UTC"
  end

  # The JSON spelling writes the receiver's own offset (what `JsonRender`
  # sends) while the stored form stays UTC, so writes sort and round-trip.
  def test_json_spelling_carries_the_offset_while_the_stored_form_stays_utc
    Snails.time_zone = "Seoul"
    t = "2024-01-02 03:04:05.000006".to_time
    assert_equal "2024-01-02T12:04:05.000+09:00", t.to_fs(:iso8601)
    assert_equal "2024-01-02 03:04:05.000006", t.to_fs(:db)
    Snails.time_zone = "UTC"
  end

  # A UTC receiver keeps its own day: the helper must not read the UTC civil
  # date and rebuild it in the process zone (Seoul would shift the boundary).
  def test_utc_receiver_keeps_its_day
    Snails.time_zone = "Seoul"
    midnight = Time.utc(2024, 1, 2, 3, 4, 5).beginning_of_day
    assert_equal Time.utc(2024, 1, 2), midnight
    assert_equal 0, midnight.utc_offset
    Snails.time_zone = "UTC"
  end

  # A fixed-offset value from `in_time_zone` rebuilds in that offset: the
  # boundary is New York's midnight, not Seoul's.
  def test_foreign_zone_boundary_lands_in_that_zone
    Snails.time_zone = "Seoul"
    midnight = Time.utc(2024, 1, 2, 3, 4, 5).in_time_zone("America/New_York").beginning_of_day
    assert_equal Time.utc(2024, 1, 1, 5), midnight
    assert_equal(-18000, midnight.utc_offset)
    Snails.time_zone = "UTC"
  end

  # A process-zone receiver keeps the zone's DST rule for the boundary: the
  # fall-back day's midnight is EDT even though noon is EST.
  def test_process_zone_boundary_follows_dst
    Snails.time_zone = "Eastern Time (US & Canada)"
    begin
      midnight = Time.local(2024, 11, 3, 12, 0, 0).beginning_of_day
      assert_equal Time.utc(2024, 11, 3, 4), midnight
      assert_equal(-14400, midnight.utc_offset)
    ensure
      Snails.time_zone = "UTC"
    end
  end
end

FixtureRunner.run(ProcessZoneRenderTest, [
  "test_time_now_reads_the_pinned_offset",
  "test_stored_text_lands_in_the_pinned_zone",
  "test_model_datetime_read_lands_in_the_pinned_zone",
  "test_json_spelling_carries_the_offset_while_the_stored_form_stays_utc",
  "test_utc_receiver_keeps_its_day",
  "test_foreign_zone_boundary_lands_in_that_zone",
  "test_process_zone_boundary_follows_dst"
])
