# Error Handling

A missing record is a 404, a malformed request is a 400, and an unhandled exception is a 500. The dispatcher owns those defaults so a controller does not repeat them; the app decides when a different shape — a JSON error document, a conflict status, a redirect — is the better answer.

## What the dispatcher answers

| Failure | Status | Body |
|---|---:|---|
| No route matches | 404 | `{"error":"not_found"}` |
| Body or query does not parse | 400 | `{"error":"bad_request"}` |
| Required parameter missing | 400 | `{"error":"bad_request"}` |
| `Sqlx::RecordNotFound` escapes the action | 404 | `{"error":"not_found"}` |
| Any other exception | 500 | `internal server error` (plain text) |

The last row is the server's last resort, not a JSON error. A 500 does not include the exception message in the response; the exception and the request go to the log as `request.failed`.

A response whose status is 500 or higher is also recorded as `request.failed`, even when the action returned it instead of raising. A 4xx response is a completed request.

## Handle a missing record once

The scaffold base class customizes the default 404 for every action and filter in one place:

```ruby
class ApplicationController < ActionController::API
  def process_action(action_name)
    super
  rescue Sqlx::RecordNotFound
    head(:not_found, content_type: "application/json; charset=utf-8")
  end
end
```

`Post.find` and `Post.find_by!` raise; `process_action` runs every action, so one rescue covers them all. `head` sends the status and headers without a body. `super` is required: it runs the filter chain and the action, and an override that replaces the dispatch must call `send_action(action_name)` instead so the action still gets its implicit 204.

Rescue a second class the same way when the app has a better answer for it:

```ruby
def process_action(action_name)
  super
rescue Sqlx::RecordNotFound
  render(json: { "error" => "not_found" }, status: :not_found)
rescue Sqlx::RecordNotUnique
  render(json: { "error" => "conflict" }, status: :conflict)
end
```

For a case that belongs to one action, use a normal `begin`/`rescue` in that action. Do not rescue `Exception`; the runtime re-raises `SystemExit`, `SignalException`, and `NoMemoryError` at its own boundaries, and catching them in app code only moves the failure.

## The error classes

| Class | Raised when |
|---|---|
| `Sqlx::RecordNotFound` | `find`, `find_by!`, or an app `raise` names a missing row |
| `Sqlx::RecordNotUnique` | an INSERT or UPDATE trips a unique index |
| `Sqlx::Busy` | a database lock wait exceeds the adapter's budget |
| `Sqlx::ConnectionTimeout` | a connection checkout waits past the pool budget |
| `Sqlx::ConnectionFailed` | the database session is gone |
| `ActionController::ParameterMissing` | `Params.require_key` finds no value |
| `Sqlx::RecordInvalid` | app code constructs it for a failed record |
| `Sqlx::ValueTooLong` | app code constructs it for an over-long value |

`RecordInvalid` and `ValueTooLong` have no core raiser. They exist so an app can use one error vocabulary and one rescue list; constructing them is the app's choice.

`Sqlx::Busy` means the unit did not commit, so retry the whole transaction or job. `Sqlx::ConnectionFailed` may leave the unit's outcome unknown — the statement may have committed — so retry the whole unit, never one statement inside it. `ConnectionTimeout` means the statement did not run, so the same retry rule applies.

There is no `rescue_from`. Registration is a plain method override, which keeps the dispatch path readable and makes the order of rescues explicit. `ActionController::UnpermittedParameters` and `ActionController::UnknownFormat` exist for rescue clauses but no runtime path raises them.

## Failures in the background

A job that raises is recorded by the job stack and does not stop the worker loop. The DB-backed queue writes the exception class and message to the queue row; there is no retry. A periodic callback that raises becomes a `scheduler.callback_failed` record and does not stop the other callbacks. [Background Jobs](15-background-jobs.md) covers the queue lifecycle.

A failed request keeps its server log. `bin/test` names the kept log path on a failed load; `bin/dev` streams to `tmp/development.log` and appends. `snails doctor` checks the setup before you go looking for an exception.

[Logging](21-logging.md) covers the record fields a failure leaves behind.
