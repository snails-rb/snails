# The route-pattern target: a path capture proves the request span uses the
# low-cardinality route pattern rather than the concrete path.
class HarnessTraceProbeController < ApplicationController
  def show
    render(json: { "id" => params["id"] })
  end
end
