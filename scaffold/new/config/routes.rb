# The route table only — controllers load through gen/controllers.rb.
#
# The verb helpers (get/post/put/delete) and `resources` come from core
# (snails-core/snails/route_dsl.rb), which boot requires before this file. The
# table is built on the first dispatch, after boot has loaded the controllers,
# so the constants it names are already initialized.
module Snails
  module RouteTable
    def self.table
      [
        get("/up", Snails::HealthController, :show)
      ]
    end
  end
end
