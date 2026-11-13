# Concurrency

A Snails server runs one process with one green thread per connection and a small pool of OS worker threads. Jobs run in the same process on their own worker threads. This chapter covers what that means for your code: what is shared, what is not, and how to size the database pool.

## The server

Every connection gets a green thread. A thread parked on a slow client, a keep-alive wait, or a database round trip frees its OS worker for another connection, so one process can hold many connections without one process per connection.

The banner shows the process model:

```text
manual-demo (spinel) listening on http://0.0.0.0:3000, pid 74898
  one green thread per connection; OS workers: one per core (SPINEL_WORKERS=N to cap); processes: 1
```

`SPINEL_WORKERS` caps the OS worker threads; without it the runtime uses one per core. The server accepts `-w N` and `WORKERS`, but it runs one process. Run more copies of the binary (or more containers) when one process is not enough; each copy is independent.

`SIGTERM` and `SIGINT` set a stop flag that the accept loop checks once a second. The server exits on the next check instead of waiting out keep-alive connections; a client that needs a graceful drain should stop sending new work before the signal.

## The database pool

Each process has its own pool. `DATABASE_POOL_SIZE` sets its size (default `8`). A request checks out a connection on its first database access and releases it at the request boundary. On SQLite the pool is split into shards so request threads do not contend on one mutex; on PostgreSQL every connection is a libpq session.

Size the pool for the work that can touch the database at the same time: request threads plus `WORKER_CONCURRENCY` job threads. A pool that is too small does not corrupt anything; it makes a checkout wait. On PostgreSQL the wait ends as `Sqlx::ConnectionTimeout` after `DATABASE_POOL_TIMEOUT_MS` (default 5000). On SQLite a writer waits on the database lock up to `DATABASE_BUSY_TIMEOUT_MS` (default 5000) and then raises `Sqlx::Busy`.

A request that never touches a model never checks out a connection, which is why `GET /up` stays cheap even under load.

## Jobs

The server starts the job loop and one worker thread at boot. `WORKER_CONCURRENCY` raises the thread count:

```sh
WORKER_CONCURRENCY=6 bin/dev
```

Each worker thread takes its own database connection and runs a drain. With the default process queue, one drain takes every due job, so extra worker threads mostly help when jobs enqueue while another drain is running. With `ActiveJob::DatabaseQueue`, the claim is one atomic UPDATE, so rows are split across workers and N jobs can run at once; global first-in-first-out order is only guaranteed at one worker.

A job runs outside a request, on the job thread's own database lease. A model call in a job therefore needs no request context. The pool constraint applies here too: N job threads plus request threads must fit in `DATABASE_POOL_SIZE`.

The process queue holds at most 1,000 pending jobs. A full queue drops the new hand-off and writes one local warning; it does not grow without bound. The DB queue has no such cap because its rows are in the database.

## What is shared

| State | Shared across processes? |
|---|---|
| Database rows | Yes — the database is the shared store |
| `Snails.cache` | No — one store per process |
| `ActiveJob::ProcessQueue` | No — jobs live in the process that enqueued them |
| `ActiveJob::DatabaseQueue` rows | Yes — any process with the same database can drain them |
| `ActiveJob::Scheduler` recurring beats | No — each process runs its own beat; the DB queue's interval record deduplicates the enqueue |
| Open database connections | No — one pool per process |

If a value must be visible to another process, put it in the database. If work must survive a restart, use the DB queue. If a recurring job must fire once across processes, `ActiveJob.recurring` with the DB queue is the one that deduplicates recurring runs by interval window.

## The request boundary

The dispatcher parks the current request and controller on the thread for the duration of an action (`ActionController::Current`). It clears them in `ensure`, so code outside an action sees `nil`. A job has no request context.

A request's database reads are cached for the request's lifetime; a write clears the cache. The cache is per request, not per process, so a read after a write in the same request sees the write.

[Local Development](22-local-development.md) shows the banner and the build loop; [Deploying](25-deploying.md) covers the container setup.
