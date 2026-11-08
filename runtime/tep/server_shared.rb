# The HTTP answers and the one process record every server shares. Both write
# paths spell a status line from `reason`, the body drains map their outcome
# through `body_error_status`/`body_error_message`, and every server process
# leaves one `process.started` record via `log_process_started`.
module Tep
  # the reason phrase for a status line. Codes this server spells out answer
  # their phrase; any other code answers "OK".
  #
  # @param status [Integer] the response status code
  # @return [String] the reason phrase, "OK" when the code is not listed
  def self.reason(status)
    if status == 200; return "OK"; end
    if status == 201; return "Created"; end
    if status == 204; return "No Content"; end
    if status == 301; return "Moved Permanently"; end
    if status == 302; return "Found"; end
    if status == 304; return "Not Modified"; end
    if status == 400; return "Bad Request"; end
    if status == 401; return "Unauthorized"; end
    if status == 403; return "Forbidden"; end
    if status == 404; return "Not Found"; end
    if status == 408; return "Request Timeout"; end
    if status == 413; return "Payload Too Large"; end
    if status == 500; return "Internal Server Error"; end
    "OK"
  end

  # the response status for a body drain outcome the server must answer. `:ok`
  # never reaches here.
  #
  # @param outcome [Symbol] :too_large, :timeout, or :incomplete
  # @return [Integer] 413, 408, or 400
  def self.body_error_status(outcome)
    return 413 if outcome == :too_large
    return 408 if outcome == :timeout
    400
  end

  # the one-line client message that pairs with `body_error_status`.
  #
  # @param outcome [Symbol] :too_large, :timeout, or :incomplete
  # @return [String] the message for the response body
  def self.body_error_message(outcome)
    return "request body too large" if outcome == :too_large
    return "request body timed out" if outcome == :timeout
    "incomplete request body"
  end

  # the one `process.started` record each server process leaves after any
  # prefork. The record carries the listener and backend fields; the app,
  # environment, pid, and core version ride as resource attributes, so the local
  # line stays short.
  #
  # @param port [Integer] the listening port
  # @param workers [Integer] the prefork process count
  # @return [void]
  def self.log_process_started(port, workers)
    worker_concurrency = ActiveJob::Launcher.concurrency
    Snails.logger.info(
      "process " + Tep.display_name + " started on port " + port.to_s,
      event: "process.started",
      fields: {
        "snails.port" => port,
        "snails.workers" => workers,
        "snails.queue_adapter" => ActiveJob.queue_adapter.to_s,
        "snails.worker_concurrency" => worker_concurrency,
        "snails.db_adapter" => Sqlx.adapter_name
      }
    )
  end
end
