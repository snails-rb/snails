require_relative "test_helper"
require_relative "../snails-core/ext/date"
require_relative "harness_runner"
require_relative "test_database"

# Date support (core) — the opt-in date codec and the `date_columns`
# hydration path. The fixture app has no DATE column, so this case file
# loads the codec the generated model file loads for a DATE schema; setup owns
# a fresh table per case.
class DateSupportTest < TestBase
  class Event < Sqlx::Base
    %w[id title happens_on issued_on].each { |n| define_method(n) { read_attribute(n) } }

    def self.table_name = "events"
    def self.only_columns = [:id, :title, :happens_on, :issued_on]
    def self.date_columns = %w[happens_on issued_on]
  end

  # A declaration typo names a column outside only_columns: hydration must
  # fail loud instead of leaving the value raw.
  class BadDateModel < Sqlx::Base
    def self.table_name = "events"
    def self.only_columns = [:id, :title]
    def self.date_columns = %w[bogus_on]
  end

  def setup
    TestDatabase.configure!("date_support")
    TestDatabase.drop_tables!("events")
    TestDatabase.exec("CREATE TABLE events (id INTEGER PRIMARY KEY, title TEXT NOT NULL, happens_on DATE NOT NULL, issued_on DATE)")
    TestDatabase.exec("INSERT INTO events (title, happens_on, issued_on) VALUES ('opened', '2024-01-02', NULL)")
  end

  def assert_equal(expected, actual, msg = nil)
    raise(msg || "expected #{expected.inspect}, got #{actual.inspect}") unless expected == actual
  end

  # The stored form is the fixed ten-character date: it parses to the civil
  # date, shorter text reads nil, and the datetime codec keeps its own
  # boundary (a ten-character date is still nil for `to_time`).
  def test_string_to_date_reads_the_stored_form
    assert_equal Date.new(2024, 1, 2), "2024-01-02".to_date
    assert_equal nil, "2024-01-0".to_date
    assert_equal nil, "2024-01-02".to_time
  end

  # The model read converts a declared DATE column through the date codec;
  # a NULL stays nil instead of becoming a blank date.
  def test_model_date_columns_hydrate_as_dates
    event = Event.find(1)
    assert_equal Date.new(2024, 1, 2), event.happens_on
    assert_equal nil, event.issued_on
  end

  # A date is a civil date, so the process zone cannot move it: the same
  # stored text reads as the same date under a negative-offset zone.
  def test_date_hydration_survives_a_negative_offset_zone
    Snails.time_zone = "America/New_York"
    event = Event.find(1)
    assert_equal Date.new(2024, 1, 2), event.happens_on
    assert_equal "2024-01-02", event.happens_on.to_s
    assert_equal 2, event.happens_on.to_time.mday
    Snails.time_zone = "UTC"
  end

  # A Date value binds as the stored text on write and reads back as a Date,
  # so the column round-trips through both write entries.
  def test_date_roundtrips_through_writes_and_reads
    created = Event.create!({ title: "closed", happens_on: Date.new(2024, 2, 29), issued_on: Date.new(2024, 3, 1) })
    stored = Sqlx::Base.rows_by_sql("SELECT happens_on, issued_on FROM events WHERE id = ?", [created.id])[0]
    assert_equal "2024-02-29", stored["happens_on"]
    assert_equal "2024-03-01", stored["issued_on"]
    assert_equal Date.new(2024, 2, 29), Event.find(created.id).happens_on

    updated = Event.update!(created.id, { happens_on: Date.new(2024, 3, 1) })
    assert_equal Date.new(2024, 3, 1), updated.happens_on
  end

  # Condition values and inline literals render the same stored text, so a
  # Date compared through the conditions hash matches the stored row.
  def test_date_condition_and_literal_render_the_stored_text
    event = Event.find_by({ happens_on: Date.new(2024, 1, 2) })
    assert_equal 1, event.id
    assert_equal "'2024-01-02'", Sqlx.quote(Date.new(2024, 1, 2))
    assert_equal 1, Event.fetch_many({ happens_on: [Date.new(2024, 1, 2), Date.new(2024, 1, 3)] }).length
  end

  # JSON renders a Date as its ISO text — the same spelling the column
  # stores, so a response payload round-trips into the database.
  def test_date_renders_as_json_text
    assert_equal "{\"happens_on\":\"2024-01-02\"}",
                 ActionController::JsonRender.encode({ happens_on: Date.new(2024, 1, 2) })
  end

  # A declared date column outside the projection is a declaration typo:
  # hydration raises instead of silently leaving the value raw.
  def test_date_declaration_outside_projection_loud
    begin
      BadDateModel.from_row({ "id" => 1, "title" => "x" })
    rescue ArgumentError => error
      assert_equal "from_row: date column bogus_on is not in only_columns", error.message
      return
    end
    raise "expected ArgumentError from a date column outside only_columns"
  end
end

FixtureRunner.run(DateSupportTest, [
  "test_string_to_date_reads_the_stored_form",
  "test_model_date_columns_hydrate_as_dates",
  "test_date_hydration_survives_a_negative_offset_zone",
  "test_date_roundtrips_through_writes_and_reads",
  "test_date_condition_and_literal_render_the_stored_text",
  "test_date_renders_as_json_text",
  "test_date_declaration_outside_projection_loud"
])
