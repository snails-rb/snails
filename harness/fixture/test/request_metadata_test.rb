require_relative "test_helper"
require_relative "harness_runner"

# Request metadata and the two params views: the dispatcher wires the body
# length and format, the request exposes the Content-Type readers, and
# `request_parameters` keeps the body fields when the query overrides them in
# `params`.
class RequestMetadataTest < TestBase
  def assert_equal(expected, actual)
    raise("expected #{expected.inspect}, got #{actual.inspect}") unless expected == actual
  end

  # A request the dispatcher can route: the body is parsed through the real
  # transport reader, so `body_fields` and the parse-failure flag are set the
  # way a server request sets them.
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

  # The query value wins in `params`, while `request_parameters` keeps the
  # body value under the same name and does not gain the query-only key.
  def test_body_only_params_survive_a_query_override
    body = '{"name":"body","count":3}'
    res = dispatch("POST", "/request-probe", "name=query&extra=q", "application/json", body)
    assert_equal 200, res.status

    data = parsed(res)
    assert_equal "application/json", data["content_type"]
    assert_equal "application/json", data["media_type"]
    assert_equal body.bytesize, data["content_length"]
    assert_equal true, data["json"]
    assert_equal "json", data["format"]
    assert_equal "query", data["params_name"]
    assert_equal "query", data["request_params_name"]
    assert_equal "body", data["body_name"]
    assert_equal "q", data["params_extra"]
    assert_equal "", data["request_params_extra"]
    assert_equal false, data["query_only_in_body"]
  end

  # A `+json` structured suffix is a JSON body; the transport parses it and
  # `request.json?` agrees.
  def test_a_json_structured_suffix_is_parsed
    res = dispatch("POST", "/request-probe", "", "application/vnd.api+json", '{"name":"body"}')
    assert_equal 200, res.status
    data = parsed(res)
    assert_equal "application/vnd.api+json", data["media_type"]
    assert_equal true, data["json"]
    assert_equal "body", data["body_name"]
  end

  # A urlencoded body has the same body-only view, without the query-only key.
  def test_a_urlencoded_body_has_its_own_view
    res = dispatch("POST", "/request-probe", "name=query&extra=q", "application/x-www-form-urlencoded", "name=body")
    assert_equal 200, res.status
    data = parsed(res)
    assert_equal "query", data["params_name"]
    assert_equal "body", data["body_name"]
    assert_equal "q", data["params_extra"]
    assert_equal false, data["query_only_in_body"]
  end

  # A request with no body reports empty metadata and an empty body-only hash.
  def test_a_request_without_a_body_reports_empty_metadata
    res = dispatch("GET", "/request-probe", "", nil, nil)
    assert_equal 200, res.status
    data = parsed(res)
    assert_equal nil, data["content_type"]
    assert_equal nil, data["media_type"]
    assert_equal 0, data["content_length"]
    assert_equal false, data["json"]
    assert_equal "json", data["format"]
    assert_equal "", data["params_name"]
    assert_equal nil, data["body_name"]
    assert_equal false, data["query_only_in_body"]
  end

  # The raw readers normalize an absent or empty Content-Type and parse a
  # parameterized, mixed-case media type.
  def test_content_type_readers
    empty = ActionDispatch::Request.new({ "CONTENT_TYPE" => "" })
    assert_equal nil, empty.content_type
    assert_equal nil, empty.media_type
    assert_equal false, empty.json?

    json = ActionDispatch::Request.new({ "CONTENT_TYPE" => "Application/JSON; charset=utf-8" })
    assert_equal "Application/JSON; charset=utf-8", json.content_type
    assert_equal "application/json", json.media_type
    assert_equal true, json.json?

    vendor = ActionDispatch::Request.new({ "CONTENT_TYPE" => "application/problem+json" })
    assert_equal true, vendor.json?
  end

  # The dispatcher assigns the body length; a standalone request reports 0.
  def test_content_length_defaults_to_zero
    request = ActionDispatch::Request.new({})
    assert_equal 0, request.content_length
    request.content_length = 12
    assert_equal 12, request.content_length
  end
end

FixtureRunner.run(RequestMetadataTest, [
  "test_body_only_params_survive_a_query_override",
  "test_a_json_structured_suffix_is_parsed",
  "test_a_urlencoded_body_has_its_own_view",
  "test_a_request_without_a_body_reports_empty_metadata",
  "test_content_type_readers",
  "test_content_length_defaults_to_zero"
])
