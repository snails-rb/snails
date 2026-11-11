# Logging

Every request, job, and process event leaves a structured record you can read in the terminal and ship to a remote collector. The default output is a local line; the record carries the same fields when a transport is set.

## Where the log goes

`bin/dev` prints to your terminal and appends to a file. The startup line says where:

```text
[snails] serving myapp on http://127.0.0.1:3000
[snails] log: tmp/development.log (append)
```

Follow it with `tail -f tmp/development.log` while you work. The process announces itself once at boot:

```text
I, [2026-11-11T21:14:24.183629Z #73371]  INFO -- : event.name=process.started snails.port=3000 snails.workers=1 snails.queue_adapter=ActiveJob::ProcessQueue snails.worker_concurrency=1 snails.db_adapter=SQLite body=process myapp started on port 3000
```

## What a request leaves

Each request adds one `request.completed` record at info when it finishes:

```text
event.name=request.completed snails.request_id=bfac7f3e snails.controller=Snails::HealthController snails.action=show http.request.method=GET url.path=/up http.response.status_code=200 snails.duration_ms=0.07 snails.db_ms=0.0 snails.format=json body=GET /up 200
```

`snails.duration_ms` is the whole request; `snails.db_ms` is the part that waited on the database. The controller, action, request id, method, path, and status ride along, so one request is traceable end to end. A request that never reached a controller — a 404 or a malformed body — omits the controller and action fields.

A failure leaves `request.failed` at error instead, with the same fields plus the exception when one was raised. A returned 5xx also writes `request.failed`; a 4xx is a completed request.

## Say something yourself

The five level methods take a plain message, and a named event with fields when you have them:

```ruby
Snails.logger.info("reconciled posts", event: "posts.reconciled", fields: { count: 12 })
Snails.logger.error("provider refused", event: "mail.failed", exception: failure)
```

A call without `event:` writes a plain line and an `app.log` record. A call with `event:` is a named record rendered by the record formatter. Both reach the transport, so choosing a formatter never decides whether something is delivered. `fields:` and `exception:` require `event:`; supplying either without it raises instead of silently falling back to a plain line. Field values are strings, numbers, booleans, or nil; nested structures do not have a defined field mapping.

## Configure it

The logger slots are set once in `config/environment.rb`:

```ruby
Snails.logger.level            = :info
Snails.logger.output           = $stdout
Snails.logger.progname         = "billing"
Snails.logger.formatter        = MyFormatter.new
Snails.logger.record_formatter = MyRecordFormatter.new
Snails.logger.host_name        = "api-1"
Snails.logger.transport        = Snails::Logger::OTLPTransport.new(
  endpoint: ENV.fetch("OTLP_ENDPOINT"),
  token: ENV.fetch("OTLP_TOKEN")
)
```

Without an explicit level, development writes debug and every other mode writes info and above. `output` defaults to `$stderr`; a String path is rejected — open the file and pass the IO. `formatter` renders the plain lines, `record_formatter` renders named events, and both must answer `call` and return a newline-terminated String. `host_name` answers `ENV["HOSTNAME"]` unless set.

The core ships an OTLP/HTTP transport. Its endpoint is the receiver's base address; the transport appends the logs path itself. Endpoint and token are app-owned and come from the environment — never write their values into `config/environment.rb`.

Remote delivery is off until a transport is set. A delivery failure is reported locally and does not stop the app.

## Job and scheduler events

Jobs write `job.started`, `job.finished`, and `job.failed` with the job name, run id, attempt count, and duration. The worker and scheduler loops write `worker.drain_failed`, `worker.loop_stopped`, `scheduler.callback_failed`, `scheduler.run_failed`, and `scheduler.loop_stopped` when their units fail. Those events carry the pid and the exception, so a bad job or callback is visible without a request.

[Local Development](22-local-development.md) covers the run loop; [Error Handling](20-error-handling.md) covers which failures become a 500.
