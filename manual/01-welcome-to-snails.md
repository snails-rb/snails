# Welcome to Snails

Snails is a Rails-like framework for API-only Ruby apps. It keeps the Rails conventions — routes, controllers, models, forms, mailers, and jobs in Ruby; migrations in SQL — and compiles your app code, the framework, and the HTTP server into one native executable. The server does not depend on Ruby; the executable boots in single-digit milliseconds and handles requests concurrently without a GVL. There is no view layer or asset pipeline.

Snails is for developers who want the Rails API shape without a Ruby deployment: routes in `config/routes.rb`, controllers with actions, form objects for validation, mailers, jobs, and a conventional folder layout, all in one binary. If you need server-rendered pages, the Ruby gem ecosystem, or Active Record's object model, Rails is the better fit.

The [Why Snails](https://snails-rb.org/blog/why-snails/) article explains the six design choices and their costs. [Coming from Rails](04-coming-from-rails.md) maps the habits that carry over, and the [FAQ](28-faq.md) answers the boundary questions. The [Performance](29-performance.md) chapter has the benchmark table and measurement method.

Let's get started with the basics.
