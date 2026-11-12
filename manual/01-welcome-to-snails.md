# Welcome to Snails

Snails is a Rails-like framework for API-only Ruby apps. It keeps the Rails conventions — routes, controllers, models, forms, mailers, and jobs in Ruby; migrations in SQL — and compiles your app code, the framework, and the HTTP server into one native executable. The server does not depend on Ruby; the executable boots in single-digit milliseconds and handles requests concurrently without a GVL. There is no view layer or asset pipeline.

## Why it's fast

Ruby holds a GVL, so a single Ruby process runs only one thread of application code at a time. Rails gets around that by running several worker processes, and every worker forks its own complete copy of the application — its own connection pool, its own heap, its own resident set.

Snails compiles to native code and carries no GVL. One process runs request handlers on as many cores as the OS gives it, so throughput scales with cores without the memory scaling alongside it.

That shows up in three numbers: requests per second per host, resident memory, and time from process start to serving.

## How it compares

Both sides are generated app defaults answering the same `GET /up` with the same JSON body, run as containers on one machine: 8 cores with SMT for 16 hardware threads. Rails Cluster Mode adds one Puma worker per server hardware thread so it can use the same cores Snails uses in one process. The server is pinned to threads 4–15, six physical cores; the load generator gets threads 0–3 so it cannot steal CPU from the server. Request logging is off for the throughput and memory figures, so the measurement is the request path and not the log writer; launch time and idle memory come from a run with logging on, where it makes no difference to either.

| | Snails | Rails | Rails Cluster Mode |
|---|---:|---:|---:|
| Requests per second | 50,865 | 4,262 | 16,209 |
| Response time, 95th percentile | 1.3 ms | 11.2 ms | 4.7 ms |
| Memory while idle | 14 MiB | 95 MiB | 163 MiB |
| Memory under load | 30 MiB | 116 MiB | 701 MiB |
| Launch to first answer | 9 ms | 1.0 s | 1.0 s |
| Image size | 138 MiB | 467 MiB | 467 MiB |

The three columns are three deployments of the same app:

- **Snails** — one process, no GVL, request threads spread across the cores available to it.
- **Rails** — `rails new` untouched: `WEB_CONCURRENCY=0`, a single process with 3 threads. One core does the Ruby work no matter how many the machine has.
- **Rails Cluster Mode** — `WEB_CONCURRENCY=n`, one Puma worker per server hardware thread, 5 threads each. Five threads is Puma's default max; the generated puma.rb defaults to 3, so this column is a tuned shape, not a generated default. This is the configuration that actually uses the hardware Snails uses by default.

Against Cluster Mode, Snails answers about 3× the requests at roughly a third of the p95. The default Rails column is 11.9×, which is the number a `rails new` deployment would see before anyone configured it for load.

Memory is where the two architectures diverge most. Cluster Mode runs 12 worker processes to use 12 hardware threads, so its resident set scales with core count; under load the gap is 701 MiB against 30 MiB. Idle it is smaller and still the same shape: 163 MiB against 14 MiB.

Launch time does not follow the memory story. Cluster Mode is not meaningfully slower to start than single-process Rails, because each worker pays for loading the framework rather than for the worker count. Both land around 1.0 s. A Snails binary is answering requests in 9 ms.

The same benchmark also runs one application scenario: a single-row primary-key read over SQLite (`GET /items/:id`). At 32 connections Snails answers about 1.5× the requests of Rails Cluster Mode; the database path is the shared bottleneck. That scenario is separate from the `/up` microbenchmark and does not change the numbers above.

Figures are medians over three 15-second runs at 32 concurrent connections; launch and idle memory use five rounds, and the under-load memory figure comes from the three throughput runs. Absolute numbers belong to this hardware — the ratios are what transfer. The harness, the raw result files and the method are in [snails-benchmark](https://github.com/snails-rb/snails-benchmark), which is where these figures come from and where corrections land.

## What it doesn't do

Snails is API-only, and that's deliberate: there is no view layer, so nothing renders HTML. If you need server-rendered pages, other tools do that better. [Coming from Rails](04-coming-from-rails.md) lays out exactly which habits carry over, and the [FAQ](28-faq.md) is honest about the rest.

Let's get started with the basics.
