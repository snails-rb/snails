# Welcome to snails

snails is a small framework for building web apps that compile to a single native binary. You write ordinary Ruby — routes, controllers, models, forms — and snails turns it into one binary that boots fast and runs anywhere a binary runs. There is no runtime to install on the server, no asset pipeline, and no view layer: your app answers with JSON.

## Why it's fast

Ruby runs one thread of your code at a time by default. Rails gets past that by running several worker processes, and each worker holds its own full copy of your app in memory. snails has no such limit, so one process can use every CPU the machine has. That means one process to watch, one log to tail, and no multiplying memory just to use more CPUs.

You feel it in three places: how many requests one machine answers, how much memory it sits on, and how long a deploy or a restart takes.

## How it compares

Both apps answer the same `GET /up` with the same JSON body, running as containers on the same machine: eight cores, sixteen hardware threads. The app gets twelve of those threads, and the load generator keeps the other four so it never competes with the app being measured.

| | snails | Rails | Rails, one worker per CPU |
|---|---:|---:|---:|
| Requests per second | 35,000 | 3,950 | 14,000 |
| Response time, 95th percentile | 1.7 ms | 11 ms | 4.8 ms |
| Memory while idle | 14 MiB | 99 MiB | 187 MiB |
| Launch to first answer | 8 ms | 1.3 s | 1.3 s |
| Image size | 145 MB | 445 MB | 445 MB |

Nine times the requests of a stock Rails app, and about two and a half times one that has been scaled up to use the same CPUs. The last column is the fairer one to read, because it's what Rails needs in order to use what snails uses by default. The middle column is what `rails new` hands you untouched.

Each figure is the median of repeated runs on that machine at 32 simultaneous connections. Your numbers will differ; what travels is the shape of it: several times the traffic per CPU, memory measured in megabytes instead of hundreds of them, and a restart you can't perceive.

## What it doesn't do

snails is API-only, and that's deliberate: there is no view layer, so nothing renders HTML. If you need server-rendered pages, other tools do that better. [Coming from Rails](04-coming-from-rails.md) lays out exactly which habits carry over, and the [FAQ](18-faq.md) is honest about the rest.

Let's get started with the basics.
