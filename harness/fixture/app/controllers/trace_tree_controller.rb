# The contract target for the tracing tree: an app span wraps one DB read and
# one enqueue, so the request span, app span, DB span, producer span, and the
# later consumer span can be asserted together.
class HarnessTraceTreeController < ApplicationController
  def show
    Snails.tracer.in_span("app.work", attributes: { "app.key" => "value" }) do
      Sqlx::Database.exec_read("SELECT 1 AS one", [])
      ActiveJob.enqueue(HarnessTraceTreeJob, { "n" => 1 })
    end
    render(json: { "ok" => true })
  end
end
