# The route table only — controllers load through gen/controllers.rb.
#
# The verb helpers (get/post/put/delete) and `resources` come from core
# (snails-core/snails/route_dsl.rb), which boot requires before this file. The
# table is built on the first dispatch, after boot has loaded the controllers,
# so the constants it names are already initialized.
#
# The scaffold's example API: posts, with comments nested under a post.
module Snails
  module RouteTable
    def self.table
      [
        get("/up", Snails::HealthController, :show),
        *resources("/posts", Api::PostsController, :json),
        *resources("/posts/:post_id/comments", Api::CommentsController, :json)
      ]
    end
  end
end
