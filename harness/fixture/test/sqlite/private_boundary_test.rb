require_relative "../test_helper"
require_relative "../harness_runner"
require_relative "../../snails-core/snails/harness"

# The private boundaries of the first batch — each module's helpers are
# reachable only through its public entry; an app calling one from outside
# gets NoMethodError instead of a quietly working answer.
class PrivateBoundaryTest < TestBase
  def assert_private_method(object, label, name)
    return unless object.respond_to?(name)

    raise "expected #{label}##{name} to be private"
  end

  # The recurring fire helper is internal: `recurring` is the public
  # declaration, so an app calling the fire helper is refused.
  def test_active_job_recurring_fire_is_private
    begin
      ActiveJob.enqueue_recurring(JSON.parse("{}"))
    rescue NoMethodError
      return
    end
    raise "expected ActiveJob.enqueue_recurring to be private"
  end

  # JsonRender's helpers sit behind `encode`; an app calling one from
  # outside is refused.
  def test_json_render_helpers_are_private
    begin
      ActionController::JsonRender.jsonify("x")
    rescue NoMethodError
      return
    end
    raise "expected ActionController::JsonRender.jsonify to be private"
  end

  # Router's match helpers sit behind `match`; an app calling one from
  # outside is refused.
  def test_router_helpers_are_private
    begin
      ActionDispatch::Router.format_extension("json")
    rescue NoMethodError
      return
    end
    raise "expected ActionDispatch::Router.format_extension to be private"
  end

  # The civil helpers sit behind the public date/time calculations; an app
  # calling one from outside is refused.
  def test_date_time_helpers_are_private
    begin
      Snails::DateAndTime::Calculations.local_time(2026, 1, 1, 0, 0, 0, 0)
    rescue NoMethodError
      return
    end
    raise "expected DateAndTime::Calculations.local_time to be private"
  end

  # The TZif reader helpers sit behind `in_time_zone`; an app calling one
  # from outside is refused.
  def test_time_zone_helpers_are_private
    begin
      Snails::TimeZone.posix_seconds("00")
    rescue NoMethodError
      return
    end
    raise "expected Snails::TimeZone.posix_seconds to be private"
  end

  # The request builder sits behind `Harness.request`; an app calling it
  # from outside is refused.
  def test_harness_request_builder_is_private
    begin
      Snails::Harness.request_object(:get, "/")
    rescue NoMethodError
      return
    end
    raise "expected Snails::Harness.request_object to be private"
  end

  # The status table sits behind `assert_response`; an app calling it from
  # outside is refused.
  def test_harness_status_table_is_private
    c = Snails::Harness::IntegrationTest.new
    begin
      c.expected_status(:ok)
    rescue NoMethodError
      return
    end
    raise "expected Snails::Harness.expected_status to be private"
  end

  # The adapter's cursor, column, bind, and escape helpers are implementation
  # details; an app calling one from outside is refused.
  def test_database_low_level_helpers_are_private
    helpers = [
      "prepare",
      "step?",
      "column_int",
      "bind_int",
      "escape_string"
    ]
    helpers.each do |name|
      begin
        case name
        when "prepare"
          Sqlx::Database.prepare("SELECT 1")
        when "step?"
          Sqlx::Database.step?(0)
        when "column_int"
          Sqlx::Database.column_int(0, 0)
        when "bind_int"
          Sqlx::Database.bind_int(0, 1, 1)
        when "escape_string"
          Sqlx::Database.escape_string("x")
        end
      rescue NoMethodError
        next
      end
      raise "expected Sqlx::Database." + name + " to be private"
    end
  end

  # The server helpers sit behind `run`; an app calling one from outside is
  # refused, and the public `send_simple` path is gone.
  def test_tep_server_helpers_are_private
    scheduled = Tep::Server::Scheduled.new
    threaded = Tep::Server::Threaded.new

    assert_private_method(scheduled, "Tep::Server::Scheduled", :run_connection)
    assert_private_method(scheduled, "Tep::Server::Scheduled", :accept_loop)
    assert_private_method(scheduled, "Tep::Server::Scheduled", :handle_connection)
    assert_private_method(scheduled, "Tep::Server::Scheduled", :handle_one)
    assert_private_method(scheduled, "Tep::Server::Scheduled", :read_request_blob)
    assert_private_method(scheduled, "Tep::Server::Scheduled", :write_response)
    assert_private_method(scheduled, "Tep::Server::Scheduled", :send_simple)

    assert_private_method(threaded, "Tep::Server::Threaded", :run_connection)
    assert_private_method(threaded, "Tep::Server::Threaded", :handle_connection)
    assert_private_method(threaded, "Tep::Server::Threaded", :handle_one)
    assert_private_method(threaded, "Tep::Server::Threaded", :read_request_blob)
    assert_private_method(threaded, "Tep::Server::Threaded", :write_response)
    assert_private_method(threaded, "Tep::Server::Threaded", :send_simple)

    begin
      scheduled.send_simple(-1, 200, "x")
    rescue NoMethodError
      return
    end
    raise "expected Tep::Server::Scheduled#send_simple to be private"
  end

  # The WebSocket dispatch and frame writers sit behind `run`, `text`, and
  # `close`; an app calling one from outside is refused.
  def test_websocket_helpers_are_private
    driver = Tep::WebSocket::Driver.new(-1)
    connection = Tep::WebSocket::Connection.new(driver, nil)

    assert_private_method(connection, "Tep::WebSocket::Connection", :dispatch_frame)
    assert_private_method(connection, "Tep::WebSocket::Connection", :dispatch_open)
    assert_private_method(connection, "Tep::WebSocket::Connection", :dispatch_message)
    assert_private_method(connection, "Tep::WebSocket::Connection", :dispatch_ping)
    assert_private_method(connection, "Tep::WebSocket::Connection", :dispatch_pong)
    assert_private_method(connection, "Tep::WebSocket::Connection", :dispatch_close)
    assert_private_method(driver, "Tep::WebSocket::Driver", :send_frame)
    assert_private_method(driver, "Tep::WebSocket::Driver", :encode_close_payload)

    begin
      connection.dispatch_open(driver)
    rescue NoMethodError
      begin
        driver.send_frame(-1, Tep::WebSocket::OPCODE_TEXT, "")
      rescue NoMethodError
        return
      end
      raise "expected Tep::WebSocket::Driver#send_frame to be private"
    end
    raise "expected Tep::WebSocket::Connection#dispatch_open to be private"
  end
end

FixtureRunner.run(PrivateBoundaryTest, [
  "test_active_job_recurring_fire_is_private",
  "test_json_render_helpers_are_private",
  "test_router_helpers_are_private",
  "test_date_time_helpers_are_private",
  "test_time_zone_helpers_are_private",
  "test_harness_request_builder_is_private",
  "test_harness_status_table_is_private",
  "test_database_low_level_helpers_are_private",
  "test_tep_server_helpers_are_private",
  "test_websocket_helpers_are_private"
])
