# Welcome to Snails

Snails is a Rails-like framework for API-only Ruby apps. It keeps the Rails conventions — routes, controllers, models, forms, mailers, and jobs in Ruby; migrations in SQL — and compiles your app code, the framework, and the HTTP server into one native executable. The server does not depend on Ruby; the executable boots in single-digit milliseconds and handles requests concurrently without a GVL. There is no view layer or asset pipeline.

Snails is deliberately smaller than Rails. It has no Active Record and no gem compatibility. Models are plain classes over SQL, and migrations are SQL files. The CLI and the server run without Ruby, and `bin/test` runs the suite against a real HTTP server. The [Why Snails](https://snails-rb.org/blog/why-snails/) article explains the reasoning and the cost of each choice.

If you need server-rendered pages, the Ruby gem ecosystem, or Active Record's object model, Rails is the better fit. [Coming from Rails](04-coming-from-rails.md) maps the habits that carry over, and the [FAQ](28-faq.md) answers the boundary questions.

The [Performance](29-performance.md) chapter has the benchmark table and method.

Let's get started with the basics.
