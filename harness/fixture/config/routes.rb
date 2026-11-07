require_relative "../app/controllers/application_controller"
require_relative "../app/controllers/filter_controller"
require_relative "../app/controllers/boom_controller"
require_relative "../app/controllers/current_probe_controller"
require_relative "../app/controllers/db_probe_controller"
require_relative "../app/controllers/body_params_controller"

module Snails
  module RouteTable
    def self.table
      # The bare paren helper form: `get` is core's (snails-core/snails/route_dsl.rb),
      # this file only reopens the module for its table.
      [get("/up", Snails::HealthController, :show),
       get("/boom", HarnessBoomController, :show),
       get("/not-implemented", HarnessBoomController, :not_implemented),
       get("/server-error", HarnessBoomController, :server_error),
       get("/current-probe", HarnessCurrentProbeController, :show),
       get("/db-probe", HarnessDbProbeController, :show),
       post("/body-params", HarnessBodyParamsController, :show)]
    end
  end
end
