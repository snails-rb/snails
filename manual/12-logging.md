# Logging

Every request, job, and process event leaves a structured record you can read while the app runs.

## Where the log goes

`bin/dev` prints to your terminal and appends to a file — the startup line says where:

```text
[snails] serving demo on http://127.0.0.1:3000
[snails] log: tmp/development.log (append)
```

Follow it with `tail -f tmp/development.log` while you work.

## What a record looks like

The process announces itself once at boot:

```text
I, [2026-11-06T23:08:30.657874Z #212514]  INFO -- : event.name=process.started snails.port=3000 snails.workers=1 snails.queue_adapter=ActiveJob::ProcessQueue snails.worker_concurrency=1 snails.db_adapter=SQLite body=process demo started on port 3000
```

Each request adds one line when it finishes — the method, path, status, and timing in one place:

```text
event.name=request.completed  GET /up 200  snails.duration_ms=0.4  snails.db_ms=0.3  snails.format=json
```

`snails.duration_ms` is the whole request; `snails.db_ms` is the part that waited on the database. The controller, action, and request id ride along as context, so one request is traceable end to end.

## Say something yourself

The level methods take a plain message, and a named event with fields when you have them:

```ruby
Snails.logger.info("reconciled posts", event: "posts.reconciled", fields: { count: 12 })
```

In development the level is debug, so everything shows; raise it in `config/environment.rb` with `Snails.logger.level` when the noise gets in the way.
