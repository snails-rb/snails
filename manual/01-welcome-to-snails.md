# Welcome to snails

snails is a small framework for building web apps that compile to a single native binary. You write ordinary Ruby — routes, controllers, models, forms — and snails turns it into one binary that boots fast and runs anywhere a binary runs. There is no runtime to install on the server, no asset pipeline, and no view layer: your app answers with JSON.

## Why it's fast

Ruby executes one thread of application code at a time. Rails works around that by running several worker processes, and every worker holds its own copy of the application in memory. snails has no such constraint: a single process uses every core on the machine, with no GVL and no process-per-core duplication.

That shows up as throughput per core, resident memory, and restart time.

## How it compares

Both apps are generated defaults answering the same `GET /up` with the same JSON body, in containers on one machine — 8 cores, 16 hardware threads. The app gets twelve threads; the load generator is pinned to the other four so it never competes with the server. Request logging is off on both sides, so what is measured is the framework request path.

| | snails | Rails | Rails Cluster Mode |
|---|---:|---:|---:|
| Requests per second | 57,863 | 4,920 | 18,547 |
| Response time, 95th percentile | 1.1 ms | 9.4 ms | 4.0 ms |
| Memory while idle | 14 MiB | 98 MiB | 184 MiB |
| Memory under load | 39 MiB | 141 MiB | 866 MiB |
| Launch to first answer | 8 ms | 1.5 s | 1.6 s |
| Image size | 138 MiB | 416–424 MiB | 416–424 MiB |

Cluster Mode is the column that matters for a like-for-like comparison: one worker per core is what Rails needs to reach the parallelism snails gets from a single process. The unlabelled Rails column is `rails new` untouched — one process, five threads — and is what most deployments start as.

The memory gap widens under load rather than narrowing. Cluster Mode pays for one copy of the app per worker, so its footprint scales with core count; a snails process does not.

Figures are medians of repeated runs at 32 concurrent connections. Expect different absolute numbers on your hardware — the ratios are the part that holds. The harness, the committed result files and the full method are in [snails-benchmark](https://github.com/snails-rb/snails-benchmark); that repository is the source of these figures and where corrections land.

## What it doesn't do

snails is API-only, and that's deliberate: there is no view layer, so nothing renders HTML. If you need server-rendered pages, other tools do that better. [Coming from Rails](04-coming-from-rails.md) lays out exactly which habits carry over, and the [FAQ](18-faq.md) is honest about the rest.

Let's get started with the basics.
