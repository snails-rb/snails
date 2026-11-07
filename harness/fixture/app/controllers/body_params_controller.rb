# Body params probe — the action reads the params the dispatcher built from
# the request body, so a case can tell a payload that parsed from one that did
# not, and `require_key` gives the missing-parameter path a live caller.
class HarnessBodyParamsController < ApplicationController
  def show
    name = ActionController::Params.require_key(params, "name")
    render(json: { "name" => name })
  end
end
