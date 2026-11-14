# Welcome to Snails

Snails is a Rails-like framework for API-only Ruby apps. It keeps the Rails conventions — routes, controllers, models, forms, mailers, and jobs in Ruby; migrations in SQL — and compiles your app code, the framework, and the HTTP server into one native executable. The server does not depend on Ruby. There is no view layer or asset pipeline.

It keeps the developer-friendly conventions and removes the abstractions that add runtime overhead: no Active Record and no gem compatibility. Models are plain classes over SQL, migrations are SQL files, and `bin/test` runs against a real HTTP server. Coding agents change the work those abstractions were designed for: they write SQL, maintain a backend and a frontend as two stacks, and implement missing behavior in the app. See [The Snails Design](https://snails-rb.org/blog/the-snails-design/) for the abstraction trade and the agent workflow behind these choices.

Snails compiles to native code and carries no GVL. It boots in single-digit milliseconds. One process uses the available cores without a worker process per core, and memory does not grow with a worker count. The [Performance](29-performance.md) chapter has the benchmark table, method, and comparison.

The [Coming from Rails](04-coming-from-rails.md) chapter covers the Rails features that carry over and what replaces the rest. The [FAQ](28-faq.md) lists what is not included.

Let's get started with the basics.
