# Coming from Rails

If you know Rails, you already know most of Snails. Routes are declared the same way, controllers answer with JSON instead of views, and models are plain classes over your tables. This chapter is the translation layer for the habits you bring: where routes live now, what replaces Active Record, and which Rails features you will not find here.

## What stays the same

- Routes live in `config/routes.rb` and use the same helpers — `get`, `post`, `put`, `delete`, and `resources`.
- Controllers are classes with actions, and parameters arrive on the request object.
- The database changes the same way: a numbered file under `db/migrate/`, applied in order, with a schema dump your tests load. See [Migrations](12-migrations.md).
- A test suite runs with one command: `bin/test`. See [Testing](24-testing.md).

## What changes

| In Rails | In Snails |
|---|---|
| Views and templates | Nothing renders HTML — your app answers with JSON (see [Routes and Controllers](06-routes-and-controllers.md)) |
| Active Record models | Plain model classes over your tables (see [Database and Models](09-database-and-models.md)) |
| `Gemfile` and Bundler | `spin.toml` declares what the build needs |
| A server process you install | One native binary that includes the server |
| Asset pipeline | Not needed — there is nothing to compile for the browser |
| `ActionController::Parameters` | A String-keyed Hash plus `ActionController::Params` helpers (see [Requests and Parameters](07-requests-and-parameters.md)) |
| `rails generate` | `snails generate`, with one generator today: `job_queue` |
| `rails db:migrate` | `snails migrate apply`, with `load` for first setup |
| `rails test` | `bin/test` |
| `perform_later` and job callbacks | `ActiveJob.enqueue`, `schedule`, and `recurring`; one class-side `perform` (see [Background Jobs](15-background-jobs.md)) |

## What is not here

Some Rails features you may reach for simply do not exist, and that is deliberate:

- No model callbacks, associations, or validations on the database layer — validation lives in form objects instead (see [Forms and Validation](13-forms.md)).
- No HTML view helpers, CSRF tokens, sessions, or cookies middleware — the framework is API-only by design. Request cookies are parsed, but there is no session store.
- No gems in the runtime sense — your app and the framework compile together into one binary.
- No `rescue_from`. A controller rescues in an action, or overrides `process_action` for an app-wide answer (see [Error Handling](20-error-handling.md)).
- No `ActiveSupport::Concern`, `included do`, or `class_methods`. A concern is a plain module; write the methods it adds.
- No `before_action` inheritance. Registration belongs to the controller class that writes it, not to its subclasses. Declare the filter on each controller that needs it, or share the method through a parent.
- No class-instance-variable inheritance. A value set on a parent class is not copied to a subclass; use a module constant or an explicit method.

The list is not a backlog. [Why Snails](https://snails-rb.org/blog/why-snails/) explains the common thread: the conventions that make an API app legible stay, and the layers that assume a monolithic app, a Ruby runtime, or a full ORM go.

The ActiveSupport surface is deliberately smaller than Rails'. The helpers that do exist are listed in [Ruby Helpers](19-ruby-helpers.md); a call to something outside that list fails at build time instead of silently doing nothing.

## Where to look next

When you reach for a Rails feature, the replacement is usually one chapter away:

- Request input: [Requests and Parameters](07-requests-and-parameters.md)
- Queries and transactions: [Querying](10-querying.md)
- Schema dumps and migrations: [Migrations](12-migrations.md)
- Auth challenges: [Authentication](08-authentication.md)
- Cache: [Caching](18-caching.md)
- Errors: [Error Handling](20-error-handling.md)

When the replacement is not there, the [FAQ](28-faq.md) says what is not included, and [Troubleshooting](27-troubleshooting.md) covers the errors a Rails habit usually produces.
