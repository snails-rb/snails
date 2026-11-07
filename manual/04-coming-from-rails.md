# Coming from Rails

If you know Rails, you already know most of snails. Routes are declared the same way, controllers respond with JSON instead of views, and models are plain classes over your tables. This chapter is the translation layer for the habits you bring: where routes live now, what replaces Active Record, and which Rails features you will not find here.

## What stays the same

You keep the shape of the parts you already know:

- Routes live in `config/routes.rb` and use the same helpers — `get`, `post`, `put`, `delete`, and `resources`.
- Controllers are classes with actions, and parameters arrive on the request object.
- The database changes the same way: a numbered file under `db/migrate/`, applied in order, with a snapshot your tests load. See [Migrations](08-migrations.md).
- A test suite runs with one command: `bin/test`. See [Testing](14-testing.md).

## What changes

| In Rails | In snails |
|---|---|
| Views and templates | Nothing renders HTML — your app answers with JSON (see [Routes and Controllers](06-routes-and-controllers.md)) |
| Active Record models | Plain model classes over your tables (see [Database and Models](07-database-and-models.md)) |
| `Gemfile` and Bundler | `spin.toml` declares what the build needs |
| A server process you install | One native binary that includes the server |
| Asset pipeline | Not needed — there is nothing to compile for the browser |

## What is not here

Some Rails features you may reach for simply do not exist, and that is deliberate:

- No model callbacks, associations, or validations on the database layer — validation lives in form objects instead (see [Forms](09-forms.md)).
- No HTML helpers or CSRF tokens — the framework is API-only by design.
- No gems in the runtime sense — your app and the framework compile together into one binary.

When you find yourself looking for a Rails feature, check the [FAQ](18-faq.md) first, then [Troubleshooting](17-troubleshooting.md).
