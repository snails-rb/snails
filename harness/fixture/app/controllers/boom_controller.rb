# The error-path target for the request line: its action raises, so the
# status=500 summary and the server's stack report have a live caller.
class HarnessBoomController < ApplicationController
  def show
    raise "boom"
  end

  # NotImplementedError is a ScriptError, not a StandardError: the HTTP
  # boundary must still answer 500 and keep serving.
  def not_implemented
    raise NotImplementedError, "not implemented"
  end

  # A controller that returns a 5xx without raising: the request still ends
  # as `request.failed`, with no exception on the record.
  def server_error
    render(json: { "error" => "internal" }, status: :internal_server_error)
  end
end
