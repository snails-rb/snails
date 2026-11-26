# CORS boundary target: a before_action halts with 401 before the action
# runs, so the dispatcher must put the CORS headers on the filter's response.
class HarnessAuthProbeController < ApplicationController
  before_action :require_credentials

  def show
    render(json: { "ok" => true })
  end

  def require_credentials
    render(json: { "error" => "unauthorized" }, status: :unauthorized)
  end
end
