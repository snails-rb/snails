# The framework's `/up` liveness endpoint. Core-owned: every app serves
# the route by declaring it in config/routes.rb, and no app or scaffold
# carries a controller copy.
module Snails
  # Liveness probe — `show` answers 200 with a JSON status body. The app
  # is API-only, so the health response is JSON like every other route
  # (no HTML page): a monitor reading the body gets a stable JSON body, and a
  # probe that only checks the status code is served by the 200 itself.
  class HealthController < ActionController::API
    # the liveness answer; the route table calls it as `:show`.
    #
    # @return [void]
    def show
      render(json: { "status" => "ok" })
    end
  end
end
