require_relative "test_helper"
require_relative "harness_runner"

# JSON body arrays in the params views: a JSON array keeps every element, the
# same shape an urlencoded `tags[]` produces, while scalar values stay Strings.
# The cases run the real dispatcher so the body reader and the query merge
# contract are exercised together.
class RequestJsonArrayTest < TestBase
  def assert_equal(expected, actual)
    raise("expected #{expected.inspect}, got #{actual.inspect}") unless expected == actual
  end

  # A request the dispatcher can route: the body is parsed through the real
  # transport reader, so `json_body` and the parse-failure flag are set the way
  # a server request sets them.
  def build_request(method, path, query, content_type, body)
    req = Tep::Request.new
    req.verb = method
    req.path = path
    req.raw_path = query.empty? ? path : path + "?" + query
    req.raw_query = query
    req.remote_host = +"127.0.0.1"
    unless content_type.nil?
      req.req_headers["content-type"] = content_type
    end
    unless body.nil?
      req.raw_body = body
      req.req_headers["content-length"] = body.bytesize.to_s
      req.parse_body_params
    end
    req
  end

  def dispatch(method, path, query, content_type, body)
    res = Tep::Response.new
    Snails::Main.dispatch(build_request(method, path, query, content_type, body), res)
    res
  end

  def parsed(res)
    JSON.parse(res.body)
  end

  # A scalar array keeps every element in both params views, while the scalar
  # values keep the params String rule.
  def test_json_scalar_array_keeps_every_element
    body = '{"tags":["red","blue"],"count":3,"active":true,"empty":null}'
    res = dispatch("POST", "/request-probe", "", "application/json", body)
    assert_equal 200, res.status

    data = parsed(res)
    assert_equal ["red", "blue"], data["tags"]
    assert_equal ["red", "blue"], data["body_tags"]
    assert_equal "3", data["count"]
    assert_equal true, data["count_is_string"]
    assert_equal "true", data["active"]
    assert_equal "", data["empty"]
  end

  # An array of objects with the same keys keeps both elements, including the
  # fields that the old flat-hash path dropped.
  def test_json_object_array_keeps_every_element
    body = '{"items":[{"sku":"A"},{"sku":"B"}]}'
    res = dispatch("POST", "/request-probe", "", "application/json", body)
    assert_equal 200, res.status

    data = parsed(res)
    assert_equal [{ "sku" => "A" }, { "sku" => "B" }], data["items"]
  end

  # Objects with disjoint keys are separate elements; the old path merged them
  # into one object because the flat hash could not hold a second element.
  def test_json_object_array_with_disjoint_keys_keeps_every_element
    body = '{"items":[{"a":1},{"b":2}]}'
    res = dispatch("POST", "/request-probe", "", "application/json", body)
    assert_equal 200, res.status

    data = parsed(res)
    assert_equal [{ "a" => "1" }, { "b" => "2" }], data["items"]
  end

  # The query array replaces the top-level value in `params`, while
  # `request.request_parameters` keeps the body array.
  def test_query_array_overrides_params_but_not_request_parameters
    body = '{"tags":["body-a","body-b"]}'
    res = dispatch("POST", "/request-probe", "tags[]=query-a&tags[]=query-b", "application/json", body)
    assert_equal 200, res.status

    data = parsed(res)
    assert_equal ["query-a", "query-b"], data["tags"]
    assert_equal ["body-a", "body-b"], data["body_tags"]
  end

  # The urlencoded form keeps its array shape, which is the contract the JSON
  # body now matches.
  def test_urlencoded_array_has_the_same_shape
    res = dispatch("POST", "/request-probe", "", "application/x-www-form-urlencoded", "tags[]=red&tags[]=blue")
    assert_equal 200, res.status

    data = parsed(res)
    assert_equal ["red", "blue"], data["tags"]
    assert_equal ["red", "blue"], data["body_tags"]
  end

  # The narrowing layer accepts the preserved array, so an app can permit the
  # same fields it permitted before.
  def test_permit_shapes_the_preserved_array
    body = '{"items":[{"sku":"A","drop":"x"},{"sku":"B","drop":"y"}]}'
    res = dispatch("POST", "/request-probe", "", "application/json", body)
    assert_equal 200, res.status

    data = parsed(res)
    permitted = ActionController::Params.permit(data, [{ items: [:sku] }])
    assert_equal [{ "sku" => "A" }, { "sku" => "B" }], permitted[:items]
  end
end

FixtureRunner.run(RequestJsonArrayTest, [
  "test_json_scalar_array_keeps_every_element",
  "test_json_object_array_keeps_every_element",
  "test_json_object_array_with_disjoint_keys_keeps_every_element",
  "test_query_array_overrides_params_but_not_request_parameters",
  "test_urlencoded_array_has_the_same_shape",
  "test_permit_shapes_the_preserved_array"
])
