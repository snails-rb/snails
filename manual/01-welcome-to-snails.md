# Welcome to Snails

Snails is a Rails-like framework for API-only Ruby apps. It keeps the Rails conventions — routes, controllers, models, forms, mailers, and jobs in Ruby; migrations in SQL — and compiles your app code, the framework, and the HTTP server into one native executable. The server does not depend on Ruby; the executable boots in single-digit milliseconds and handles requests concurrently without a GVL. There is no view layer or asset pipeline.

Snails keeps the Rails conventions that make an API app predictable, and exposes a small surface: no Active Record and no gem compatibility. Models are plain classes over SQL, migrations are SQL files, the CLI and server run without Ruby, and `bin/test` crosses a real HTTP boundary. The [Why Snails](https://snails-rb.org/blog/why-snails/) article explains the design and the purpose behind each choice.

[Coming from Rails](04-coming-from-rails.md) maps the habits that carry over, and the [FAQ](28-faq.md) answers the boundary questions. The [Performance](29-performance.md) chapter has the benchmark table and method.

Let's get started with the basics.
