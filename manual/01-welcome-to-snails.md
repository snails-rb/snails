# Welcome to Snails

Snails is a small framework for building web apps that compile to a single native binary. You write ordinary Ruby — routes, controllers, models, forms — and Snails turns it into one binary that boots fast and runs anywhere a binary runs. There is no runtime to install on the server, no asset pipeline, and no view layer: your app answers with JSON.

## Why it's fast

Ruby holds a GVL, so a single Ruby process runs only one thread of application code at a time. Rails gets around that by running several worker processes, and every worker forks its own complete copy of the application — its own connection pool, its own heap, its own resident set.

Snails compiles to native code and carries no GVL. One process runs request handlers on as many cores as the OS gives it, so throughput scales with cores without the memory scaling alongside it.

That shows up in three numbers: requests per second per host, resident memory, and time from process start to serving.

## How it compares

Both sides are framework defaults answering the same `GET /up` with the same JSON body, run as containers on one machine: 8 cores with SMT for 16 hardware threads. The server is pinned to threads 4–15, six physical cores; the load generator gets threads 0–3 so it cannot steal CPU from the server. Request logging is off for the throughput and memory figures, so the measurement is the request path and not the log writer; launch time and idle memory come from a run with logging on, where it makes no difference to either.

| | Snails | Rails | Rails Cluster Mode |
|---|---:|---:|---:|
| Requests per second | 57,863 | 4,920 | 18,547 |
| Response time, 95th percentile | 1.1 ms | 9.4 ms | 4.0 ms |
| Memory while idle | 14 MiB | 98 MiB | 184 MiB |
| Memory under load | 39 MiB | 141 MiB | 866 MiB |
| Launch to first answer | 8 ms | 1.5 s | 1.6 s |
| Image size | 138 MiB | 416–424 MiB | 416–424 MiB |

The three columns are three deployments of the same app:

- **Snails** — one process, no GVL, request threads spread across the cores available to it.
- **Rails** — `rails new` untouched: `WEB_CONCURRENCY=0`, a single process with 5 threads. One core does the Ruby work no matter how many the machine has.
- **Rails Cluster Mode** — `WEB_CONCURRENCY=n`, one Puma worker per core, 5 threads each. This is the configuration that actually uses the hardware Snails uses by default.

Against Cluster Mode, Snails answers 3.1× the requests at a quarter of the p95. The default Rails column is 11.8×, which is the number a `rails new` deployment would see before anyone configured it for load.

Memory is where the two architectures diverge most. Cluster Mode holds 12 copies of the application to use 12 hardware threads, so its resident set scales with core count; under load the gap is 866 MiB against 39 MiB. Idle it is smaller and still the same shape: 184 MiB against 14 MiB.

Launch time does not follow the memory story. Cluster Mode is not meaningfully slower to start than single-process Rails, because each worker pays for loading the framework rather than for the worker count. Both land around 1.5 s. A Snails binary is answering requests in 8 ms.

Figures are medians over three 15-second runs at 32 concurrent connections; launch time and memory use five rounds. Absolute numbers belong to this hardware — the ratios are what transfer. The harness, the raw result files and the method are in [snails-benchmark](https://github.com/snails-rb/snails-benchmark), which is where these figures come from and where corrections land.

## What it doesn't do

Snails is API-only, and that's deliberate: there is no view layer, so nothing renders HTML. If you need server-rendered pages, other tools do that better. [Coming from Rails](04-coming-from-rails.md) lays out exactly which habits carry over, and the [FAQ](18-faq.md) is honest about the rest.

Let's get started with the basics.
