require_relative "../app/controllers/application_controller"
require_relative "../app/controllers/filter_controller"
require_relative "../app/controllers/boom_controller"
require_relative "../app/controllers/current_probe_controller"
require_relative "../app/controllers/auth_probe_controller"
require_relative "../app/controllers/db_probe_controller"
require_relative "../app/controllers/trace_probe_controller"
require_relative "../app/controllers/trace_tree_controller"
require_relative "../app/controllers/body_params_controller"
require_relative "../app/controllers/cookie_probe_controller"
require_relative "../app/controllers/request_probe_controller"

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
       get("/trace-probe/:id", HarnessTraceProbeController, :show),
       post("/body-params", HarnessBodyParamsController, :show),
       get("/request-probe", HarnessRequestProbeController, :show),
       post("/request-probe", HarnessRequestProbeController, :show),
       get("/cast-error", HarnessBoomController, :cast_error),
       get("/cookie-read", HarnessCookieController, :read),
       get("/cookie-write", HarnessCookieController, :write),
       get("/cookie-delete", HarnessCookieController, :delete),
       get("/cookie-permanent", HarnessCookieController, :permanent),
       get("/auth-probe", HarnessAuthProbeController, :show),
       get("/trace-tree-probe", HarnessTraceTreeController, :show)]
    end
  end
end
