# One real statement so the request record's `snails.db_ms` has a non-zero
# value to assert. The route is harness-only and not part of the app contract.
class HarnessDbProbeController < ApplicationController
  def show
    rows = Sqlx::Database.exec_read("SELECT 1 AS one", [])
    render(json: { "one" => rows[0]["one"] })
  end
end
