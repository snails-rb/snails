require_relative "test_helper"
require_relative "harness_runner"

# RouteTable verb helpers (core, snails-core/snails/route_dsl.rb) — each
# helper builds its row with the right HTTP verb and the RESTful default
# action, an explicit action overrides that default, and the controller
# class travels on the row (instantiable through it). Pure table
# construction; no server. The fixture's own /up row is built by the
# same helpers, so the reopen + bare-call path is exercised too.
class RouteDslTest < TestBase
  def assert_equal(expected, actual, msg = nil)
    raise(msg || "expected #{expected.inspect}, got #{actual.inspect}") unless expected == actual
  end

  # GET builds a row with the collection action as its default.
  def test_get_defaults_to_index
    row = Snails::RouteTable.get("/servers", ApplicationController)
    assert_equal "GET", row.verb
    assert_equal "/servers", row.pattern
    assert_equal :index, row.action
  end

  # POST builds a row with the creation action as its default.
  def test_post_defaults_to_create
    row = Snails::RouteTable.post("/login", ApplicationController)
    assert_equal "POST", row.verb
    assert_equal :create, row.action
  end

  # PUT builds a row with the update action as its default.
  def test_put_defaults_to_update
    row = Snails::RouteTable.put("/account/password", ApplicationController)
    assert_equal "PUT", row.verb
    assert_equal :update, row.action
  end

  # DELETE builds a row with the destruction action as its default.
  def test_delete_defaults_to_destroy
    row = Snails::RouteTable.delete("/servers/:id", ApplicationController)
    assert_equal "DELETE", row.verb
    assert_equal :destroy, row.action
  end

  # An explicit third argument overrides each helper's default action.
  def test_explicit_action_overrides_default
    assert_equal :show, Snails::RouteTable.get("/servers/:id", ApplicationController, :show).action
    assert_equal :confirm, Snails::RouteTable.post("/signup", ApplicationController, :confirm).action
  end

  # The row carries the controller class and instantiates through it.
  def test_controller_class_travels_on_the_row
    row = Snails::RouteTable.get("/servers", ApplicationController)
    assert_equal ApplicationController, row.controller
    assert_equal true, row.controller.new.is_a?(ApplicationController)
  end

  # Helpers pass no format — a row with no format gets nil.
  def test_helper_rows_carry_no_format
    row = Snails::RouteTable.get("/servers", ApplicationController)
    assert_equal nil, row.req_format
  end

  # The fixture's /up row is built by the core helper (reopen + bare
  # call exercised through the app's own table); /boom is the error-path
  # target the request-line test dispatches to; /db-probe is the DB-timing
  # probe; /body-params is the POST target the body-parse test drives.
  def test_fixture_table_row_is_built_by_the_helper
    rows = Snails::RouteTable.table
    assert_equal 7, rows.length
    assert_equal "GET", rows[0].verb
    assert_equal "/up", rows[0].pattern
    assert_equal :show, rows[0].action
    assert_equal Snails::HealthController, rows[0].controller
    assert_equal "/boom", rows[1].pattern
    assert_equal HarnessBoomController, rows[1].controller
    assert_equal "/not-implemented", rows[2].pattern
    assert_equal HarnessBoomController, rows[2].controller
    assert_equal :not_implemented, rows[2].action
    assert_equal "/server-error", rows[3].pattern
    assert_equal HarnessBoomController, rows[3].controller
    assert_equal :server_error, rows[3].action
    assert_equal "/current-probe", rows[4].pattern
    assert_equal HarnessCurrentProbeController, rows[4].controller
    assert_equal "/db-probe", rows[5].pattern
    assert_equal HarnessDbProbeController, rows[5].controller
  end
end

FixtureRunner.run(RouteDslTest, [
  "test_get_defaults_to_index",
  "test_post_defaults_to_create",
  "test_put_defaults_to_update",
  "test_delete_defaults_to_destroy",
  "test_explicit_action_overrides_default",
  "test_controller_class_travels_on_the_row",
  "test_helper_rows_carry_no_format",
  "test_fixture_table_row_is_built_by_the_helper"
])
