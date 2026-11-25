# Welcome to Snails

Snails is a Rails-like framework for API-only Ruby apps. It keeps the Rails conventions: routes, controllers, models, forms, mailers, and jobs in Ruby, and migrations in SQL. It compiles your app code, the framework, and the HTTP server into one native executable. The server doesn't need Ruby at runtime, and there's no view layer or asset pipeline.

It drops the runtime machinery: no Active Record and no gem compatibility. Models are plain classes over SQL, migrations are SQL files, and `bin/test` runs against a real HTTP server. The build generates the column readers, path helpers, and the app's require list. Coding agents change the trade-off: they write SQL, work across a backend and a frontend, and implement what a gem would have provided instead of adding a dependency. See [The Snails Design](https://snails-rb.org/blog/the-snails-design/) for the reasoning and the agent workflow behind these choices.

Snails compiles to native code and has no GVL. It boots in single-digit milliseconds. One process uses the available cores, without a worker process per core, and memory doesn't grow with the worker count. [Performance](29-performance.md) has the benchmark table, method, and comparison.

If you know Rails, [Coming from Rails](04-coming-from-rails.md) maps what carries over and what replaces the rest. The [FAQ](28-faq.md) lists what isn't included.

Let's get started with the basics.
