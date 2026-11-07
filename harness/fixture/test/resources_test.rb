require_relative "test_helper"
require_relative "harness_runner"

# Snails::RouteTable.resources (core) — the five RESTful rows of a
# resource in declaration order (collection before member), the
# controller class carried on every row (and instantiable through it),
# the route-forced format when given, nil format when not, and the
# `only` filter (named actions kept, REST order regardless of list
# order, unknown name raises). Pure table construction; no server.
class ResourcesTest < TestBase
  def assert_equal(expected, actual, msg = nil)
    raise(msg || "expected #{expected.inspect}, got #{actual.inspect}") unless expected == actual
  end

  def test_five_rows_in_rest_order
    rows = Snails::RouteTable.resources("/posts", ApplicationController)
    assert_equal 5, rows.length
    assert_equal ["GET", "POST", "GET", "PUT", "DELETE"], rows.map { |r| r.verb }
    assert_equal ["/posts", "/posts", "/posts/:id", "/posts/:id", "/posts/:id"], rows.map { |r| r.pattern }
    assert_equal [:index, :create, :show, :update, :destroy], rows.map { |r| r.action }
  end

  def test_controller_carried_on_every_row
    rows = Snails::RouteTable.resources("/posts", ApplicationController)
    rows.each do |r|
      assert_equal ApplicationController, r.controller
    end
  end

  # The carried value is the class itself: `matched.controller.new` is
  # the only instantiation path (no per-app symbol -> class case).
  def test_controller_class_instantiates
    rows = Snails::RouteTable.resources("/posts", ApplicationController)
    controller = rows[0].controller.new
    assert_equal ApplicationController, controller.class
  end

  def test_format_given_lands_on_every_row
    rows = Snails::RouteTable.resources("/posts", ApplicationController, :json)
    rows.each do |r|
      assert_equal :json, r.req_format
    end
  end

  def test_format_omitted_is_nil
    rows = Snails::RouteTable.resources("/posts", ApplicationController)
    rows.each do |r|
      assert_equal nil, r.req_format
    end
  end

  def test_nested_path_keeps_parent_segments
    rows = Snails::RouteTable.resources("/posts/:post_id/comments", ApplicationController)
    assert_equal "/posts/:post_id/comments", rows[0].pattern
    assert_equal "/posts/:post_id/comments/:id", rows[2].pattern
  end

  def test_only_keeps_named_actions
    rows = Snails::RouteTable.resources("/servers", ApplicationController, :json, [:index])
    assert_equal 1, rows.length
    assert_equal "GET", rows[0].verb
    assert_equal "/servers", rows[0].pattern
    assert_equal :index, rows[0].action
    assert_equal :json, rows[0].req_format
  end

  def test_only_keeps_rest_order_regardless_of_list_order
    rows = Snails::RouteTable.resources("/devices", ApplicationController, :json, [:show, :create])
    assert_equal 2, rows.length
    assert_equal ["POST", "GET"], rows.map { |r| r.verb }
    assert_equal ["/devices", "/devices/:id"], rows.map { |r| r.pattern }
    assert_equal [:create, :show], rows.map { |r| r.action }
  end

  def test_only_unknown_action_raises
    begin
      Snails::RouteTable.resources("/posts", ApplicationController, :json, [:indx])
    rescue ArgumentError
      return
    end
    raise "expected ArgumentError from an unknown only action"
  end
end

FixtureRunner.run(ResourcesTest, [
  "test_five_rows_in_rest_order",
  "test_controller_carried_on_every_row",
  "test_controller_class_instantiates",
  "test_format_given_lands_on_every_row",
  "test_format_omitted_is_nil",
  "test_nested_path_keeps_parent_segments",
  "test_only_keeps_named_actions",
  "test_only_keeps_rest_order_regardless_of_list_order",
  "test_only_unknown_action_raises"
])
