<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/brand/mark-white.svg">
    <img src="assets/brand/mark.svg" alt="Snails" width="96">
  </picture>
</p>

# Snails

[![ci](https://github.com/snails-rb/snails/actions/workflows/ci.yml/badge.svg)](https://github.com/snails-rb/snails/actions/workflows/ci.yml)
[![release](https://img.shields.io/github/v/release/snails-rb/snails?display_name=release&label=version)](https://github.com/snails-rb/snails/releases/latest)

Snails is a Rails-like framework for API-only Ruby apps. It keeps the Rails conventions, drops the Ruby runtime, and compiles the app, the framework, and the HTTP server into one native binary. One process, multi-threaded, across all cores: no worker processes, no GVL. On the benchmark, Snails serves about 3× the requests per second of Rails in cluster mode, with more than 10× lower peak memory under load.

Snails is at 1.x, and the public API is stable. The conventions are the compatibility promise, and they won't change.

## Why Snails

Snails keeps the Rails conventions an API needs and removes the layers that add runtime overhead: the view layer, Active Record, and gem compatibility. The design trade is explained in [The Snails Design](https://snails-rb.org/blog/the-snails-design/); [Coming from Rails](manual/04-coming-from-rails.md) covers what carries over and what replaces the rest.

The story behind this choice is in [Why I didn't rewrite my Rails app in Rust](https://snails-rb.org/blog/why-i-didnt-rewrite-my-rails-app-in-rust/). A Snails app uses about 20 MB RSS, with a 4.3 MB binary; the node uses 362 MB and has 589 MB available.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/snails-rb/snails/main/install.sh | bash
snails new demo
demo/bin/test
```

Or let mise manage the CLI:

```sh
mise use -g 'github:snails-rb/snails[asset_pattern=snails-dist-*.tar.gz,version_prefix=v]'
snails new demo
```

Keep the CLI at or above the framework version you pin. To upgrade an existing install, run the install command again; it replaces the linked CLI.

`snails new` downloads the pinned compiler for Linux amd64/arm64 or macOS Apple Silicon/Intel. `bin/dev` and `bin/test` compile the app, so install the packages under [Requirements](manual/02-getting-started.md#requirements) before the first run. [Getting Started](manual/02-getting-started.md) has the full flow.

## Benchmark

The Rails comparison lives in [snails-benchmark](https://github.com/snails-rb/snails-benchmark). Both sides answer the same `GET /up` with the same JSON body on the same 8-core machine. On that microbenchmark, Snails answers about 3× the requests per second that Rails does in cluster mode. Peak memory is more than 10× lower under load, and throughput is about 11.9× that of a default Rails app. A separate single-row database read is about 3.1× faster than Rails, close to the microbenchmark ratio.

Reproduce from that repository with `bin/bench`, `bin/bench-scenario`, `bin/boottime`, and `bin/imagesize`. The result tables are under [`results/`](https://github.com/snails-rb/snails-benchmark/tree/main/results).

## Start here

The manual is the product documentation for developers building an app. It lives in [`manual/`](manual/) and is published at [snails-rb.org](https://snails-rb.org/).

- [Welcome to Snails](manual/01-welcome-to-snails.md)
- [Getting Started](manual/02-getting-started.md)
- [Coming from Rails](manual/04-coming-from-rails.md)
- [Performance](manual/29-performance.md)

## Manual

**The Basics**

- [Welcome to Snails](manual/01-welcome-to-snails.md)
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
- [Performance](manual/29-performance.md)

## Development

Snails is split into the framework (`runtime/`), the CLI (`cli/`), and the project scaffolder (`scaffold/`). An app copies `runtime/` into itself as `snails-core/` and pins the revision in its own `pins.toml`.

```
runtime/        # app-agnostic framework code — copied into a consuming app as snails-core/
scaffold/       # snails new and --scaffold templates, plus the harness skeleton
bin/snails      # the CLI entry point
cli/            # the CLI implementation shipped in the dist
scripts/        # repository-only verification and release tools (not in the dist)
install.sh      # curl installer for the CLI
pins.toml       # SPINEL_REV — the spinel revision this framework is verified with
manual/         # product documentation (English)
LICENSE         # MIT
```

The repository's own checks are shell scripts under `scripts/`. Run them from the repository root:

```sh
bash scripts/test-runtime.sh
bash scripts/test-cli.sh
bash scripts/test-migrate.sh
```

`.github/workflows/ci.yml` is the pull-request gate for code changes: the Linux amd64 suite on sqlite. `platform-ci.yml` runs on main and adds PostgreSQL, macOS, arm64, and the app image. The scripts resolve and materialize the pinned spinel toolchain themselves; a global `spinel` install is not required.

## Contributing

Bug reports and focused pull requests are welcome. Read [`CONTRIBUTING.md`](CONTRIBUTING.md) and [`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md) before opening a PR, and use the issue templates for reproducible bugs or feature proposals. Questions and show-and-tell go to [Discussions](https://github.com/snails-rb/snails/discussions).

## Acknowledgements

Snails builds on [Spinel](https://github.com/matz/spinel), the Ruby AOT compiler by [Yukihiro "Matz" Matsumoto](https://github.com/matz). Spinel is what makes the one-native-binary build possible. Thank you to Matz and the Spinel contributors.

## License

MIT. See [`LICENSE`](LICENSE).

`runtime/` began as a fork of Spinel's scaffold output and has been substantially rewritten. The derived portions live in `runtime/action_controller/` and `runtime/action_dispatch/`; each carries the upstream notice in its `NOTICE` file. `runtime/tep/` follows tep's notice in `runtime/tep/NOTICE`. The rest of the `runtime/` tree is Snails' own work.
