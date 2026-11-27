# Request metadata probe — renders the readers the dispatcher wires, so a
# case can tell the body-only params from the merged ones, check the
# Content-Type and Content-Length contracts, and read the JSON array and scalar
# shapes over a real dispatch.
class HarnessRequestProbeController < ApplicationController
  def show
    body_name = request.request_parameters["name"]
    render(json: {
      "content_type" => request.content_type,
      "media_type" => request.media_type,
      "content_length" => request.content_length,
      "json" => request.json?,
      "format" => request.format,
      "tags" => params["tags"],
      "body_tags" => request.request_parameters["tags"],
      "items" => params["items"],
      "count" => params["count"],
      "count_is_string" => params["count"].is_a?(String),
      "active" => params["active"],
      "empty" => params["empty"],
      "params_name" => params["name"].to_s,
      "request_params_name" => request.params["name"].to_s,
      "body_name" => body_name.nil? ? nil : body_name.to_s,
      "params_extra" => params["extra"].to_s,
      "request_params_extra" => request.request_parameters["extra"].to_s,
      "query_only_in_body" => request.request_parameters.key?("extra")
    })
  end
end
