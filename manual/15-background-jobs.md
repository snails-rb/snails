# Background Jobs

Move slow work off the request: run a job in the background, schedule one for later, or repeat it on an interval. A job is a class with a class-side `perform`. The queue adapter decides whether the work waits in memory or in the database.

## Declare a job

The class name is the job name. Define one class-side `perform`:

```ruby
class CommentDigestJob < ActiveJob::Base
  def self.perform(data)
    CommentDigestSink::COUNTS << Comment.count
  end
end
```

The payload is passed as the only argument — a Hash, an Array, or `nil`. Put the file under `app/jobs/` and it loads through `gen/jobs.rb`, like everything else in `app/`.

A job may override `job_name` when the stored name must differ from the class name. The name must stay a constant path, because the database-backed queue looks up the class by its name. There's no `perform_later` or `perform_now` — the class is the unit, and the calls below are the API.

## Enqueue it

```ruby
ActiveJob.enqueue(CommentDigestJob, { "since" => 0 })
```

Where it runs depends on whether the process has a worker loop. A server starts a worker loop at boot, so the job waits for it and runs off the request. A test process has no loop, so it runs at the call site — which is why a test can assert on the result immediately.

A job that must run later takes a `Time`:

```ruby
ActiveJob.schedule(CommentDigestJob, Time.now + 900, { "since" => 0 })
```

`schedule` needs a worker loop. Without one it raises rather than silently ignoring the delay.

For recurring work, register a job with an interval or a cron expression:

```ruby
ActiveJob.recurring(CommentDigestJob, 5.minutes)            # every 5 minutes
ActiveJob.recurring(PruneRollupJob, schedule: "0 6 * * *")  # 06:00 UTC every day
```

The interval takes seconds or a duration such as `5.minutes` or `1.day`. Exactly one form is required. Passing both or neither raises when the schedule is declared.

One job registers once: a second `recurring` call for the same job raises when the schedule is declared, even if the expression differs. For several runs a day, put them in one cron expression, such as `0 6,18 * * *`.

The interval form runs once per interval window. Each window is aligned to a fixed clock boundary, so two processes enqueuing inside the same window compute the same start time. The cron form runs at the expression's scheduled times, in UTC. Cron expressions use the five-field `man 5 crontab` grammar (minute hour day-of-month month day-of-week) with lists, ranges, steps, three-letter month and weekday names, and the `@daily`-family aliases. A seconds field, a time zone, and natural language are rejected when the schedule is declared.

Both forms start at the next occurrence: a process that starts after the scheduled time waits for the next one. An occurrence that passed while no process was alive isn't caught up. Each run enqueues the job, and the worker loop executes it like any other job. With the DB adapter, the occurrence table keeps each occurrence to one enqueue across processes and restarts.

## Choose a queue adapter

The default is `ActiveJob::ProcessQueue`: jobs live as procs in the process that enqueued them and are drained by that process's worker loop. Nothing survives a restart, and a full queue (1,000 pending) drops the new job with one local warning.

The DB-backed adapter stores each job as a row in the app's database. Its payload must be a JSON value, because the row stores it as JSON text. The process queue keeps the proc and accepts any Ruby object.

```ruby
# config/environment.rb
ActiveJob.queue_adapter = ActiveJob::DatabaseQueue
```

Generate the table and the wiring with:

```sh
snails generate job_queue
```

The generator writes `db/migrate/<UTC>_create_snails_queue.sql` and refreshes `db/schema.sql`, then prints the adapter line and a commented retention registration. With the DB adapter, queued work survives a restart, and any process with the same database can drain it. A recurring occurrence is deduplicated across processes by a small table that records which occurrence already ran. A finished row is the run's history: status, attempts, start and finish time, and the last error.

Retention is off until the app puts the prune job on the clock:

```ruby
ActiveJob.recurring(Snails::Queue::PruneJob, 1.day)
```

`PruneJob` deletes finished rows older than seven days in batches. Without it, finished rows accumulate — each one is still the run's history.

## Workers and failures

The server starts a worker loop with one worker thread at boot. A drain is one pass that runs the due jobs. `WORKER_CONCURRENCY` raises the thread count, and each worker thread takes its own database connection and drains through the selected adapter. At one worker thread the queue is first-in-first-out. Above one, the DB adapter's atomic claim splits rows across worker threads, so global FIFO is no longer guaranteed. [Concurrency](23-concurrency.md) covers the pool sizing.

A job that raises becomes a `job.failed` record and doesn't stop the drain. The DB adapter writes the exception class and message to the row. Job bodies aren't retried.

A delivery failure isn't a job failure. The running binary couldn't execute the row. The stored job name has no class in this binary (an old and a new deploy sharing one queue), or the row's payload isn't valid JSON. The DB adapter returns the row to pending with a growing delay — 30 seconds first (`DELIVERY_RETRY_SECONDS`), doubling up to 10 minutes (`DELIVERY_MAX_DELAY_SECONDS`). The row gets `DELIVERY_MAX_ATTEMPTS` attempts (ten) before it becomes `failed` with `handler_not_found: <name>` or `payload_unreadable: ...` in its last error. That failed row is the dead letter.

A job whose process died while running is marked failed after an hour and isn't queued again — a second run could duplicate work the first one is still doing. Snails has no liveness signal for its processes. A job that legitimately runs longer than an hour is also marked failed while it runs, and its own result overwrites that row when it finishes.

`ProcessQueue` caps pending work at 1,000. When a producer outruns the drain, the new job is dropped instead of growing the process. The warning is local and doesn't enqueue another job.

A recurring callback that raises becomes a `scheduler.callback_failed` record and doesn't stop the other callbacks or the loop.

[Error Handling](20-error-handling.md) covers the request-side failure record. [Logging](21-logging.md) covers the `job.*` events.
