# Snails

[![ci](https://github.com/snails-rb/snails/actions/workflows/ci.yml/badge.svg)](https://github.com/snails-rb/snails/actions/workflows/ci.yml)

Snails is a Rails-like framework for API-only Ruby apps. It keeps the Rails conventions — routes, controllers, models, forms, mailers, and jobs in Ruby; migrations in SQL — and compiles your app code, the framework, and the HTTP server into one native executable. The server does not depend on Ruby; the executable boots in single-digit milliseconds and handles requests concurrently without a GVL. There is no view layer or asset pipeline.

The project is split into parts: the API-only, Rails-like runtime for [Spinel](https://github.com/matz/spinel) (`runtime/`), the CLI (`cli/`), and the project scaffolder (`scaffold/`). A consuming app vendors the runtime as `snails-core/` and pins the revision in `pins.toml`.

Status: alpha. The public API can change between 0.x releases.

## Scope

This is not a Rails replacement. It is API-only: no views, no asset pipeline, no ActiveRecord or gem compatibility. Models are plain classes over SQL, and migrations are SQL files. See the [FAQ](manual/28-faq.md) and [Coming from Rails](manual/04-coming-from-rails.md) for the full boundary.

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

The first command that needs the toolchain assembles the pinned compiler. See [Getting Started](manual/02-getting-started.md) for the full first-project flow.

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
