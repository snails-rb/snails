# Background Jobs

Move slow work off the request: run a job in the background, schedule one for a later moment, or repeat it on an interval. A job is a class with a class-side `perform`; the queue adapter decides whether the work waits in memory or in the database.

## Declare a job

A job is a class with one class-side `perform` — the name it is filed under comes from the class name:

```ruby
class CommentDigestJob < ActiveJob::Base
  def self.perform(data)
    CommentDigestSink::COUNTS << Comment.count
  end
end
```

The payload arrives as the one argument — a Hash, an Array, or `nil`. Put the file under `app/jobs/` and it loads through `gen/jobs.rb`, like everything else in `app/`.

A job may override `job_name` when the stored name must differ from the class name. The name must stay a constant path, because a store-backed drain resolves it with `Object.const_get`. There is no `perform_later` or `perform_now` — the class is the unit, and the entries below are the calls.

## Enqueue it

```ruby
ActiveJob.enqueue(CommentDigestJob, { "since" => 0 })
```

Where it runs depends on whether the process has a job worker loop. A server starts one at boot, so the job waits for the worker loop and runs off the request. A test process has no loop, so it runs at the call site — which is why a test can assert on the result immediately.

```text
ok an enqueued job runs with its payload
```

A job that must run later takes a `Time`:

```ruby
ActiveJob.schedule(CommentDigestJob, Time.now + 900, { "since" => 0 })
```

`schedule` needs a worker loop. Without one it raises rather than silently ignoring the delay.

For work that should happen again and again, register a recurring job:

```ruby
ActiveJob.recurring(CommentDigestJob, 300)
```

The beat fires once per interval window — each interval is aligned to a fixed clock boundary, so two processes firing inside the same window compute the same start time. The current window is caught up on the first pass; windows that passed while no process was alive are not backfilled. Each fire enqueues the job; the worker loop executes it like any other job.

## Choose a queue adapter

The default is `ActiveJob::ProcessQueue`: jobs live as procs in the process that enqueued them and are drained by that process's worker loop. Nothing survives a restart, and a full queue (1,000 pending) drops the new hand-off with one local warning.

The DB-backed adapter stores each job as a row in the app's database. Its payload must be a JSON value, because the row stores it as JSON text; the process queue keeps the proc and accepts any Ruby object.

```ruby
# config/environment.rb
ActiveJob.queue_adapter = ActiveJob::DatabaseQueue
```

Generate the table and the wiring with:

```sh
snails generate job_queue
```

The generator writes `db/migrate/<UTC>_create_snails_queue.sql` and refreshes `db/schema.sql`, then prints the adapter line and a commented retention registration. With the DB adapter, queued work survives a restart, any process with the same database can drain it, and a recurring occurrence is deduplicated across processes by a small table that records which interval already ran. A finished row is the run's history: status, attempts, start and finish time, and the last error.

Retention is off until the app puts the prune job on the clock:

```ruby
ActiveJob.recurring(Snails::Queue::PruneJob, 86400)
```

`PruneJob` deletes finished rows older than seven days in batches. Without it, finished rows accumulate — each one is still the run's history.

## Workers and failures

The server starts the job loop and one worker thread at boot. A drain is one pass that runs the due jobs; `WORKER_CONCURRENCY` raises the thread count, and each worker takes its own database connection and drains through the selected adapter. At one worker the queue is first-in-first-out; above one the DB adapter's atomic claim splits rows across workers, so global FIFO is no longer promised. [Concurrency](23-concurrency.md) covers the pool sizing.

A job that raises becomes a `job.failed` record and does not stop the drain. The DB adapter writes the exception class and message to the row; there are no retries and no dead-letter queue. A job whose process died while running is returned to pending after ten minutes — at-least-once, with the attempts counter recording the lost run.

`ProcessQueue` caps pending work at 1,000. When a producer outruns the drain, the new job is dropped instead of growing the process; the warning is local and does not enqueue another job.

A recurring callback that raises becomes a `scheduler.callback_failed` record and does not stop the other callbacks or the loop.

[Error Handling](20-error-handling.md) covers the request-side failure record; [Logging](21-logging.md) covers the `job.*` events.
