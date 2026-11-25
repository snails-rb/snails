# Concurrency

A Snails server runs one process with one green thread per connection and a small pool of OS worker threads. Jobs run in the same process on their own worker threads. This chapter covers what that means for your code: what's shared, what isn't, and how to size the database pool.

## The server

Every connection gets a green thread. A thread parked on a slow client, a keep-alive wait, or a database round trip frees its OS worker for another connection. One process can hold many connections without one process per connection.

The banner shows the process model:

```text
manual-demo (spinel) listening on http://0.0.0.0:3000, pid 74898
  one green thread per connection; OS workers: main + one per core (SPINEL_WORKERS=N sets the total); processes: 1
```

`SPINEL_WORKERS` sets the total OS worker threads. Unset, the runtime uses main plus one OS worker per core. The server accepts `-w N` and `WORKERS`, but it runs one process. Run more copies of the binary (or more containers) when one process isn't enough. Each copy is independent.

The default gives two OS workers plus main on a two-core host and more on larger hosts, so leave `SPINEL_WORKERS` unset unless you need a different count. Only a one-core host gets fewer than two OS workers plus main. There, set `SPINEL_WORKERS=3` when the process also runs jobs. Setting 3 on a larger host caps the workers it would otherwise get.

`SIGTERM` and `SIGINT` set a stop flag that the accept loop checks once a second. The server exits on the next check instead of waiting out keep-alive connections. A client that needs a graceful drain should stop sending new work before the signal.

## The database pool

Each process has its own pool. `DATABASE_POOL_SIZE` sets its size (default `8`). A request checks out a connection on its first database access and releases it at the request boundary. On SQLite the pool is split into shards so green threads don't contend on one mutex. On PostgreSQL every connection is a libpq session.

Size the pool for the work that can touch the database at the same time: green threads plus `WORKER_CONCURRENCY` worker threads. A pool that is too small doesn't corrupt anything. It makes a checkout wait. On PostgreSQL the wait ends as `Sqlx::ConnectionTimeout` after `DATABASE_POOL_TIMEOUT_MS` (default 5000). On SQLite a writer waits on the database lock up to `DATABASE_BUSY_TIMEOUT_MS` (default 5000) and then raises `Sqlx::Busy`.

A request that never touches a model never checks out a connection, which is why `GET /up` stays cheap even under load.

## Jobs

The server starts a worker loop with one worker thread at boot. `WORKER_CONCURRENCY` raises the thread count:

```sh
WORKER_CONCURRENCY=6 bin/dev
```

Each worker thread takes its own database connection and runs a drain. With the default process queue, one drain takes every due job, so extra worker threads mostly help when jobs enqueue while another drain is running. With `ActiveJob::DatabaseQueue`, the claim is one atomic UPDATE, so rows are split across worker threads and N jobs can run at once. Global first-in-first-out order is only guaranteed at one worker thread.

A job runs outside a request, on the worker thread's own database lease. A model call in a job therefore needs no request context. The pool constraint applies here too: N worker threads plus green threads must fit in `DATABASE_POOL_SIZE`.

The process queue holds at most 1,000 pending jobs. A full queue drops the new job and writes one local warning. It doesn't grow without bound. The DB queue has no such cap because its rows are in the database.

### Long jobs and serving

A job that runs one long database statement holds its OS worker for the whole statement: the call has no yield point inside it. A garbage collection pause in the meantime also waits for that worker, so the other workers stall with it. While the statement runs, nothing else in the process makes progress — a weekly scan over a multi-gigabyte database can stop `GET /up` for minutes.

`SPINEL_WORKERS` reserves a worker for serving. The count includes the main thread, and connections and job workers use the remaining OS workers. A process that serves and runs jobs needs at least three (`N-1 = 2`). On a two-core or larger host the default already provides that (main plus one OS worker per core). Only a one-core host needs `SPINEL_WORKERS=3` set explicitly. The database adapters declare their calls `blocking: true`. A garbage collection pause doesn't wait for the worker running one, and the second OS worker keeps answering while the statement runs.

That still leaves one gap: a connection held by the busy worker waits for the statement, and every green thread stays on the worker it first ran on. A health check that reaches that worker times out even though the process is otherwise healthy. When a job can run for minutes, give it its own process or container instead of sharing the serving one.

## What is shared

| State | Shared across processes? |
|---|---|
| Database rows | Yes — the database is the shared store |
| `Snails.cache` | No — one store per process |
| `ActiveJob::ProcessQueue` | No — jobs live in the process that enqueued them |
| `ActiveJob::DatabaseQueue` rows | Yes — any process with the same database can drain them |
| `ActiveJob::Scheduler` periodic callbacks | No — each process runs its own callback; the DB queue's occurrence table deduplicates the enqueue |
| Open database connections | No — one pool per process |

If a value must be visible to another process, put it in the database. If work must survive a restart, use the DB queue. If a recurring job must run once across processes, `ActiveJob.recurring` with the DB queue deduplicates runs by interval window.

## The request boundary

The framework stores the current request and controller on the thread for the duration of an action (`ActionController::Current`). It clears them in `ensure`, so code outside an action sees `nil`. A job has no request context.

A request's database reads go through a query cache. A write clears it. The cache is per request, not per process, so a read after a write in the same request sees the write.

[Local Development](22-local-development.md) shows the banner and the build loop. [Deploying](25-deploying.md) covers the container setup.
