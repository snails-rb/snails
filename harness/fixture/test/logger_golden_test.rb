require_relative "test_helper"
require_relative "harness_runner"

# The golden fixture is the cross-repo reference for the P0 record shape —
# request, job, process, and app events with their context, fields, and
# resource attributes. It is not an OTLP batch; the transport is P1.
class LoggerGoldenTest < TestBase
  FILE = "logging/golden.json"

  def assert_equal(expected, actual)
    raise("expected #{expected.inspect}, got #{actual.inspect}") unless expected == actual
  end

  # All four events become records in the contract shape, with resource and
  # context kept separate.
  def test_golden_fixture_builds_the_p0_records
    entries = JSON.parse(File.read(FILE))
    assert_equal 4, entries.length

    events = []
    entries.each do |entry|
      record = Snails::Logger::Record.new(
        entry["severity"].to_sym,
        entry["event"],
        entry["body"],
        fields: entry["fields"],
        context: entry["context"],
        resource: entry["resource"]
      )
      events << record.event
      assert_equal "example-service", record.resource["service.name"]
      assert_equal 1, record.resource["snails.log.schema_version"]
    end

    assert_equal true, events.include?("request.completed")
    assert_equal true, events.include?("job.finished")
    assert_equal true, events.include?("process.started")
    assert_equal true, events.include?("app.log")

    request = Snails::Logger::Record.new(
      :info, "request.completed", "GET /up 200",
      fields: entries[0]["fields"], context: entries[0]["context"],
      resource: entries[0]["resource"]
    )
    assert_equal "ab12cd34", request.fields["snails.request_id"]
    assert_equal 200, request.fields["http.response.status_code"]
    assert_equal 0.3, request.fields["snails.db_ms"]

    job = Snails::Logger::Record.new(
      :info, "job.finished", "job ExampleJob succeeded",
      fields: entries[1]["fields"], context: entries[1]["context"],
      resource: entries[1]["resource"]
    )
    assert_equal 42, job.fields["snails.job.id"]
    assert_equal 1, job.fields["snails.job.attempt"]
    assert_equal 2.1, job.fields["snails.db_ms"]

    process = Snails::Logger::Record.new(
      :info, "process.started", "process example-service started on port 3000",
      fields: entries[2]["fields"], context: entries[2]["context"],
      resource: entries[2]["resource"]
    )
    assert_equal 3000, process.fields["snails.port"]
    assert_equal 1234, process.resource["process.pid"]
  end
end

FixtureRunner.run(LoggerGoldenTest, [
  "test_golden_fixture_builds_the_p0_records"
])
