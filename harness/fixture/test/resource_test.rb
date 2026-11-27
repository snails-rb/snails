require_relative "test_helper"
require_relative "harness_runner"

# Snails::RouteTable.resource (core) — the four rows of one singular
# resource on one path with no `:id` segment, the controller class carried on
# every row, the route-forced format, and the `only` filter with its own
# action set (no collection index, no HTML new/edit). Pure table
# construction; no server.
class ResourceTest < TestBase
  def assert_equal(expected, actual, msg = nil)
    raise(msg || "expected #{expected.inspect}, got #{actual.inspect}") unless expected == actual
  end

  # The rows are the requests a singular resource takes, in REST order: GET
  # show, POST create, PUT update, DELETE destroy, all on the same path.
  def test_four_rows_on_one_path
    rows = Snails::RouteTable.resource("/profile", ApplicationController)
    assert_equal 4, rows.length
    assert_equal ["GET", "POST", "PUT", "DELETE"], rows.map { |r| r.verb }
    assert_equal ["/profile", "/profile", "/profile", "/profile"], rows.map { |r| r.pattern }
    assert_equal [:show, :create, :update, :destroy], rows.map { |r| r.action }
  end

  # Every row carries the class, so `matched.controller.new` is the only
  # instantiation path (no per-app symbol-to-class case).
  def test_every_route_row_includes_the_controller
    rows = Snails::RouteTable.resource("/profile", ApplicationController)
    rows.each do |r|
      assert_equal ApplicationController, r.controller
    end
  end

  # The carried value is the class itself, not a name or symbol.
  def test_controller_class_instantiates
    rows = Snails::RouteTable.resource("/profile", ApplicationController)
    controller = rows[0].controller.new
    assert_equal ApplicationController, controller.class
  end

  # A route-forced format lands on every row.
  def test_format_given_lands_on_every_row
    rows = Snails::RouteTable.resource("/profile", ApplicationController, :json)
    rows.each do |r|
      assert_equal :json, r.req_format
    end
  end

  # No format argument leaves every row nil (the router infers from the path).
  def test_format_omitted_is_nil
    rows = Snails::RouteTable.resource("/profile", ApplicationController)
    rows.each do |r|
      assert_equal nil, r.req_format
    end
  end

  # A nested singular resource keeps its parent segments as path text and
  # still appends no `:id` segment.
  def test_nested_path_keeps_parent_segments
    rows = Snails::RouteTable.resource("/users/:user_id/profile", ApplicationController)
    rows.each do |r|
      assert_equal "/users/:user_id/profile", r.pattern
    end
  end

  # The subset keeps the named actions and the format.
  def test_only_keeps_named_actions
    rows = Snails::RouteTable.resource("/v1/session", ApplicationController, :json, [:show, :create, :destroy])
    assert_equal 3, rows.length
    assert_equal ["GET", "POST", "DELETE"], rows.map { |r| r.verb }
    assert_equal [:show, :create, :destroy], rows.map { |r| r.action }
    rows.each do |r|
      assert_equal :json, r.req_format
    end
  end

  # Rows come out in REST order regardless of the order named in `only`.
  def test_only_keeps_rest_order_regardless_of_list_order
    rows = Snails::RouteTable.resource("/v1/session", ApplicationController, :json, [:destroy, :show])
    assert_equal ["GET", "DELETE"], rows.map { |r| r.verb }
    assert_equal [:show, :destroy], rows.map { |r| r.action }
  end

  # The singular action set has no collection index and no HTML form actions;
  # each is refused instead of producing no row.
  def test_only_rejects_non_singular_actions
    actions = [:index, :new, :edit]
    actions.each do |action|
      begin
        Snails::RouteTable.resource("/v1/session", ApplicationController, :json, [action])
      rescue ArgumentError
        next
      end
      raise "expected ArgumentError for #{action}"
    end
  end

  # An unknown action name is refused at table construction, not silently
  # dropped.
  def test_only_unknown_action_raises
    begin
      Snails::RouteTable.resource("/v1/session", ApplicationController, :json, [:indx])
    rescue ArgumentError
      return
    end
    raise "expected ArgumentError from an unknown only action"
  end
end

FixtureRunner.run(ResourceTest, [
  "test_four_rows_on_one_path",
  "test_every_route_row_includes_the_controller",
  "test_controller_class_instantiates",
  "test_format_given_lands_on_every_row",
  "test_format_omitted_is_nil",
  "test_nested_path_keeps_parent_segments",
  "test_only_keeps_named_actions",
  "test_only_keeps_rest_order_regardless_of_list_order",
  "test_only_rejects_non_singular_actions",
  "test_only_unknown_action_raises"
])
