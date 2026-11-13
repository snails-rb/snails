# Snails

[![ci](https://github.com/snails-rb/snails/actions/workflows/ci.yml/badge.svg)](https://github.com/snails-rb/snails/actions/workflows/ci.yml)

Snails is a Rails-like framework for API-only Ruby apps. It keeps the Rails conventions — routes, controllers, models, forms, mailers, and jobs in Ruby; migrations in SQL — and compiles your app code, the framework, and the HTTP server into one native executable. The server does not depend on Ruby; the executable boots in single-digit milliseconds and handles requests concurrently without a GVL. There is no view layer or asset pipeline.

The project is split into parts: the API-only, Rails-like runtime for [Spinel](https://github.com/matz/spinel) (`runtime/`), the CLI (`cli/`), and the project scaffolder (`scaffold/`). A consuming app vendors the runtime as `snails-core/` and pins the revision in `pins.toml`.

Status: 1.0 release candidate. The public API may still change before 1.0.

## Why Snails

Snails is a deliberately minimal take on Rails, not a Rails replacement. It is built for API apps in agent-assisted development, where coding agents do much of the implementation. It keeps the Rails conventions that give an API app a predictable shape — routes in `config/routes.rb`, controllers with actions, form objects for validation, mailers, jobs, and a conventional folder layout — because they are easy for a person to read and for a coding agent to follow. It leaves out the layers that assume a monolithic stack, a Ruby runtime, or a full ORM. The scope below follows from that choice; it is not a list of unfinished features.

These are design bets, not universal rules. They assume tests and review stay in the loop; the framework's job is to keep the common path small enough to check. Rails remains the better fit for a team that wants a server-rendered monolith or the Ruby gem ecosystem.

### What it leaves out, and why

- **Views and the asset pipeline.** Rails' default frontend stack, Hotwire (Turbo and Stimulus), is part of the monolith Rails generates, shaped by Basecamp's product needs. Snails keeps the backend API-only so the frontend is a separate choice: it can live in the same repository or its own, and the JSON boundary is the contract. That gives up the integrated server-rendered workflow; in exchange, the backend does not dictate the frontend stack.
- **Active Record.** An ORM is a good fit when a team wants associations, callbacks, and one object model over the database. Snails keeps the model layer smaller: a standard query surface for the common reads and writes, with parameterized values and generated column readers, plus raw SQL for the queries that need it. The point is not that agents cannot write SQL — they can — but that a small surface cuts repeated boilerplate and gives the common path a shape that is easier to review.
- **Gem compatibility.** This is the clearest cost. The Ruby gem ecosystem assumes a Ruby runtime and a Bundler load path; a native binary has neither. The trade is a smaller dependency surface: when an app needs a small, well-understood behavior, writing it in the app can be cheaper than carrying a dependency that no longer fits the runtime. That is a bet with real costs — the app owns the code, its tests, and its security updates — and not every gem is replaceable.
- **Migrations.** A migration is a SQL file, not a Ruby DSL. The schema change stays visible as SQL, which a reviewer can read directly, and the model stays a thin class over the table. `db/schema.sql` is generated from the migration files.

The four headings above are the main architectural choices. [Coming from Rails](manual/04-coming-from-rails.md#what-is-not-here) lists the Rails API differences, and the rest of the manual documents each feature's limits.

### What this means for scope

The boundary that follows: API-only, with no HTML views or asset pipeline; no Active Record associations, callbacks, or validations; no gem compatibility; models as plain classes over SQL; migrations as SQL files. If you need server-rendered pages or the Ruby gem ecosystem, another framework is the better fit. [Coming from Rails](manual/04-coming-from-rails.md) maps the habits that carry over, and the [FAQ](manual/28-faq.md) answers the boundary questions.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/snails-rb/snails/main/install.sh | bash
snails new demo
demo/bin/test
```

Or let mise manage the CLI:

```sh
mise use -g 'github:snails-rb/snails[asset_pattern=snails-dist-*.tar.gz,version_prefix=rev-]'
snails new demo
```

While the repository has only release candidates, add `prerelease=true` to that tool entry.

The first command that needs the toolchain assembles the pinned compiler, so install the system packages listed under [Requirements](manual/02-getting-started.md#requirements) first. See [Getting Started](manual/02-getting-started.md) for the full first-project flow.

## Benchmark

The comparison against Rails is maintained in [snails-benchmark](https://github.com/snails-rb/snails-benchmark). Both sides answer the same `GET /up` with the same JSON body on the same 8-core machine. Snails does about 3× the throughput of Rails in cluster mode on that microbenchmark, with roughly 10× or more peak memory savings under load, and ~12× a default Rails app. A separate single-row DB read now measures about 3.1×, close to the microbenchmark ratio.

Reproduce from that repository with `bin/bench`, `bin/bench-scenario`, `bin/boottime`, and `bin/imagesize`. The result tables are under [`results/`](https://github.com/snails-rb/snails-benchmark/tree/main/results).

## Manual

The manual is the product documentation. It lives in [`manual/`](manual/), is written for developers building an app, and is published at [snails-rb.org](https://snails-rb.org/).

**The Basics**

- [Welcome to Snails!](manual/01-welcome-to-snails.md)
- [Getting Started](manual/02-getting-started.md)
- [Snails CLI](manual/03-snails-cli.md)
- [Coming from Rails](manual/04-coming-from-rails.md)
- [Your App's Structure](manual/05-your-app-structure.md)

**Building Your App**

- [Routes and Controllers](manual/06-routes-and-controllers.md)
- [Requests and Parameters](manual/07-requests-and-parameters.md)
- [Authentication](manual/08-authentication.md)
- [Database and Models](manual/09-database-and-models.md)
- [Querying](manual/10-querying.md)
- [Columns and Types](manual/11-columns-and-types.md)
- [Migrations](manual/12-migrations.md)
- [Forms and Validation](manual/13-forms.md)
- [Email](manual/14-email.md)
- [Background Jobs](manual/15-background-jobs.md)

**Runtime Behavior**

- [Configuration](manual/16-configuration.md)
- [Time, Dates, and JSON](manual/17-time-dates-and-json.md)
- [Caching](manual/18-caching.md)
- [Ruby Helpers](manual/19-ruby-helpers.md)
- [Error Handling](manual/20-error-handling.md)
- [Logging](manual/21-logging.md)

**Operating**

- [Local Development](manual/22-local-development.md)
- [Concurrency](manual/23-concurrency.md)
- [Testing](manual/24-testing.md)
- [Deploying](manual/25-deploying.md)
- [Updating Snails](manual/26-updating-snails.md)

**Reference**

- [Troubleshooting](manual/27-troubleshooting.md)
- [FAQ](manual/28-faq.md)

## Layout

```
runtime/        # app-agnostic core — vendored into a consuming app as snails-core/
scaffold/       # snails new and --scaffold templates, plus the harness skeleton
bin/snails      # the CLI entry point
cli/            # the CLI implementation shipped in the dist
scripts/        # repository-only verification and release tools (not in the dist)
install.sh      # curl installer for the CLI
pins.toml       # SPINEL_REV — the spinel revision this core is verified with
manual/         # product documentation (English)
LICENSE         # MIT
```

## Development

The repository's own checks are shell scripts under `scripts/`. Run them from the repository root:

```sh
bash scripts/test-runtime.sh
bash scripts/test-cli.sh
bash scripts/test-migrate.sh
```

`.github/workflows/ci.yml` is the pull-request gate: the Linux amd64 suite on sqlite. `platform-ci.yml` runs on main and adds PostgreSQL, macOS, arm64, and the app image. The scripts resolve and materialize the pinned spinel toolchain themselves; a global `spinel` install is not required.

## Contributing

Bug reports and focused pull requests are welcome. Read [`CONTRIBUTING.md`](CONTRIBUTING.md) and [`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md) before opening a PR, and use the issue templates for reproducible bugs or feature proposals. Questions and show-and-tell go to [Discussions](https://github.com/snails-rb/snails/discussions).

## License

MIT. See [`LICENSE`](LICENSE).

`runtime/` began as a fork of the Spinel scaffold emit and has been substantially rewritten. The derived portions live in `runtime/action_controller/` and `runtime/action_dispatch/`; each carries the upstream notice in its `NOTICE` file. `runtime/tep/` follows tep's notice in `runtime/tep/NOTICE`. The rest of the runtime is Snails' own work.
