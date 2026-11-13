# Welcome to Snails

Snails is a Rails-like framework for API-only Ruby apps. It keeps the Rails conventions — routes, controllers, models, forms, mailers, and jobs in Ruby; migrations in SQL — and compiles your app code, the framework, and the HTTP server into one native executable. The server does not depend on Ruby. There is no view layer or asset pipeline.

Snails keeps the Rails conventions that make an API app predictable, and exposes a small surface: no Active Record and no gem compatibility. Models are plain classes over SQL, migrations are SQL files, and `bin/test` runs against a real HTTP server. See [The Snails Design](https://snails-rb.org/blog/the-snails-design/) for the design and the purpose behind each choice.

Snails compiles to native code and carries no GVL. It boots in single-digit milliseconds. One process uses the available cores without a worker process per core, and memory does not grow with a worker count. The [Performance](29-performance.md) chapter has the benchmark table, method, and comparison.

The [Coming from Rails](04-coming-from-rails.md) chapter shows which Rails conventions carry over and what replaces the rest. The [FAQ](28-faq.md) covers what Snails does and does not include.

Let's get started with the basics.
