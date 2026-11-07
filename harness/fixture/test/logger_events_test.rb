require_relative "test_helper"
require_relative "harness_runner"
require_relative "test_database"

# A job body that succeeds without touching the database: the job event
# cases only need the queue to run it.
class LoggerEventJob < ActiveJob::Base
  def self.perform(data)
  end
end

# A job body that raises, so the failure record carries an exception.
class LoggerEventBoomJob < ActiveJob::Base
  def self.perform(data)
    raise "boom"
  end
end

# A job body that runs one real statement; the job record's db time must
# include it even on the process queue, which has no queue bookkeeping.
class LoggerEventDbJob < ActiveJob::Base
  def self.perform(data)
    Sqlx::Database.exec_read("SELECT 1 AS one", [])
  end
end

# The level contract for framework events — the same events the level
# test pins: a required event is recorded at `:info`, the optional job
# start is recorded only at `:debug`, and `:warn` still keeps errors.
# A job may also be barred from writing its own lifecycle records — the
# log delivery job is, so its records cannot feed the transport that
# enqueues it. Records are captured through the transport, so the local
# line's clock and pid never enter an assertion.
class LoggerEventsTest < TestBase
  def setup
    @capture = RecordCapture.new
    Snails.logger.output = CapturedLog.new
    Snails.logger.formatter = MessageOnlyFormatter.new
    Snails.logger.transport = nil
    Snails.logger.flush
    Snails.logger.transport = @capture
    Snails.logger.level = :info
    ActiveJob::EXECUTORS.clear
    ActiveJob::ProcessQueue::PENDING.clear
    ActiveJob.queue_adapter = ActiveJob::ProcessQueue
  end

  def assert_equal(expected, actual)
    raise("expected #{expected.inspect}, got #{actual.inspect}") unless expected == actual
  end

  def event_record(name)
    @capture.records.each do |record|
      return record if record.event == name
    end
    nil
  end

  def dispatch_get(request_path)
    TestDatabase.configure!("logger_events")
    req = Tep::Request.new
    req.verb = "GET"
    req.path = request_path
    req.raw_path = request_path
    req.remote_host = +"127.0.0.1"
    res = Tep::Response.new
    begin
      Tep::APP.dispatch(req, res)
    rescue StandardError
    end
    Snails.logger.flush
    res
  end

  def drain_one(job_class)
    ActiveJob.register_executor
    ActiveJob.enqueue(job_class)
    ActiveJob::ProcessQueue.drain
    Snails.logger.flush
  end

  # process.started is the first record a server process writes; the
  # fields name the app, environment, pid, listener, and backends.
  def test_process_started_records_the_deployment
    Tep.log_process_started(3000, 1)
    Snails.logger.flush

    record = event_record("process.started")
    assert_equal true, !record.nil?
    assert_equal :info, record.severity
    assert_equal Snails.app.app_name, record.resource["service.name"]
    assert_equal "test", record.resource["deployment.environment.name"]
    assert_equal Process.pid, record.resource["process.pid"]
    assert_equal Snails.version, record.resource["snails.version"]
    assert_equal Snails.rev, record.resource["snails.rev"]
    assert_equal 1, record.resource["snails.log.schema_version"]
    assert_equal 3000, record.fields["snails.port"]
    assert_equal 1, record.fields["snails.workers"]
    assert_equal true, record.fields["snails.queue_adapter"].include?("ProcessQueue")
    assert_equal 1, record.fields["snails.worker_concurrency"]
    assert_equal Sqlx.adapter_name, record.fields["snails.db_adapter"]
  end

  # A successful request is one info record with the matched context.
  def test_request_completed_at_info
    dispatch_get("/up")

    assert_equal 1, @capture.records.length
    record = @capture.records[0]
    assert_equal "request.completed", record.event
    assert_equal :info, record.severity
    assert_equal "GET", record.fields["http.request.method"]
    assert_equal "/up", record.fields["url.path"]
    assert_equal 200, record.fields["http.response.status_code"]
    assert_equal true, record.fields["snails.duration_ms"] >= 0.0
    assert_equal 0.0, record.fields["snails.db_ms"]
    assert_equal "Snails::HealthController", record.fields["snails.controller"]
    assert_equal "show", record.fields["snails.action"]
    assert_equal "json", record.fields["snails.format"]
    assert_equal Snails::Logger::Context.request_id, record.fields["snails.request_id"]
  end

  # A failed request is one error record; the exception is on that record,
  # not in a second stack line.
  def test_request_failed_is_one_error_record
    dispatch_get("/boom")

    assert_equal 1, @capture.records.length
    record = @capture.records[0]
    assert_equal "request.failed", record.event
    assert_equal :error, record.severity
    assert_equal 500, record.fields["http.response.status_code"]
    assert_equal 0.0, record.fields["snails.db_ms"]
    assert_equal "RuntimeError", record.exception_type
    assert_equal "boom", record.exception_message
  end

  # At :info a finished job is recorded and the optional start event is not.
  def test_job_finished_at_info
    drain_one(LoggerEventJob)

    assert_equal nil, event_record("job.started")
    record = event_record("job.finished")
    assert_equal true, !record.nil?
    assert_equal :info, record.severity
    assert_equal "LoggerEventJob", record.fields["snails.job.name"]
    assert_equal "succeeded", record.fields["snails.job.status"]
    assert_equal true, record.fields["snails.duration_ms"] >= 0.0
    assert_equal 0.0, record.fields["snails.db_ms"]
    assert_equal true, record.fields["snails.job.id"].is_a?(Integer)
    assert_equal true, record.fields["snails.job.id"] >= 1
    assert_equal 1, record.fields["snails.job.attempt"]
  end

  # At :debug the optional start event joins the finished record.
  def test_job_started_at_debug
    Snails.logger.level = :debug
    drain_one(LoggerEventJob)

    started = event_record("job.started")
    assert_equal true, !started.nil?
    assert_equal :debug, started.severity
    assert_equal "LoggerEventJob", started.fields["snails.job.name"]
    assert_equal true, !event_record("job.finished").nil?
  end

  # A failed job is an error record with the exception and failed status.
  def test_job_failed_is_an_error_record
    drain_one(LoggerEventBoomJob)

    assert_equal nil, event_record("job.started")
    record = event_record("job.failed")
    assert_equal true, !record.nil?
    assert_equal :error, record.severity
    assert_equal "LoggerEventBoomJob", record.fields["snails.job.name"]
    assert_equal "failed", record.fields["snails.job.status"]
    assert_equal 0.0, record.fields["snails.db_ms"]
    assert_equal "RuntimeError", record.exception_type
    assert_equal "boom", record.exception_message
  end

  # A DB queue job's success and failure leave records with name, id, attempt,
  # status, duration, and exception.
  def test_database_queue_job_events
    TestDatabase.configure!("logger_events")
    TestDatabase.load_queue_schema!
    ActiveJob.queue_adapter = ActiveJob::DatabaseQueue
    ActiveJob.register_executor

    ActiveJob.enqueue(LoggerEventJob)
    ActiveJob::DatabaseQueue.drain
    ActiveJob.enqueue(LoggerEventBoomJob)
    ActiveJob::DatabaseQueue.drain
    Snails.logger.flush

    finished = event_record("job.finished")
    assert_equal true, !finished.nil?
    assert_equal "LoggerEventJob", finished.fields["snails.job.name"]
    assert_equal true, finished.fields["snails.job.id"].is_a?(Integer)
    assert_equal 1, finished.fields["snails.job.attempt"]
    assert_equal "succeeded", finished.fields["snails.job.status"]
    assert_equal true, finished.fields["snails.db_ms"] > 0.0

    failed = event_record("job.failed")
    assert_equal true, !failed.nil?
    assert_equal "LoggerEventBoomJob", failed.fields["snails.job.name"]
    assert_equal "failed", failed.fields["snails.job.status"]
    assert_equal true, failed.fields["snails.db_ms"] > 0.0
    assert_equal "RuntimeError", failed.exception_type
    assert_equal "boom", failed.exception_message
  end

  # The process queue has no queue bookkeeping, so a DB-using job proves
  # that the body's statements reach the job record.
  def test_job_db_time_includes_body_statements
    TestDatabase.configure!("logger_events")

    drain_one(LoggerEventDbJob)

    record = event_record("job.finished")
    assert_equal true, !record.nil?
    assert_equal "LoggerEventDbJob", record.fields["snails.job.name"]
    assert_equal true, record.fields["snails.db_ms"] > 0.0
  end

  # The app's level wins: :warn drops the info request record but keeps the
  # error job record.
  def test_warn_drops_info_but_keeps_errors
    Snails.logger.level = :warn
    dispatch_get("/up")
    assert_equal 0, @capture.records.length

    drain_one(LoggerEventBoomJob)
    assert_equal 1, @capture.records.length
    assert_equal "job.failed", @capture.records[0].event
  end

  # While the delivery job runs, no job.* record is created for that job — such
  # a record would produce the next batch and call the delivery job again.
  # Other jobs on the same queue are still recorded.
  def test_job_events_are_dropped_only_for_the_delivery_job
    Snails::Logger::Context.begin_job(Snails::LogDeliveryJob.name, nil, nil)
    Snails.logger.info("job " + Snails::LogDeliveryJob.name + " finished", event: "job.finished")
    Snails::Logger::Context.end_job

    Snails.logger.info("job LoggerEventJob finished", event: "job.finished")
    Snails.logger.flush

    assert_equal 1, @capture.records.length
    assert_equal "job LoggerEventJob finished", @capture.records[0].body
  end
end

FixtureRunner.run(LoggerEventsTest, [
  "test_process_started_records_the_deployment",
  "test_request_completed_at_info",
  "test_request_failed_is_one_error_record",
  "test_job_finished_at_info",
  "test_job_started_at_debug",
  "test_job_failed_is_an_error_record",
  "test_database_queue_job_events",
  "test_job_db_time_includes_body_statements",
  "test_warn_drops_info_but_keeps_errors",
  "test_job_events_are_dropped_only_for_the_delivery_job"
])
