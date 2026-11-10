# snails

snails is a framework for building web apps that compile to a single native binary. You write ordinary Ruby — routes, controllers, models, forms — and snails turns it into one binary that boots fast and runs anywhere a binary runs. There is no runtime to install on the server, no asset pipeline, and no view layer: your app answers with JSON.

The project is split into parts: the API-only, Rails-like runtime for [Spinel](https://github.com/matz/spinel) (`runtime/`), the CLI (`cli/`), and the project scaffolder (`scaffold/`). A consuming app vendors the runtime as `snails-core/` and pins the revision in `pins.toml`.

Status: alpha. The public API can change between 0.x releases.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/snails-rb/dist/main/install.sh | bash
snails new demo
demo/bin/test
```

Or let mise manage the CLI:

```sh
mise use -g 'github:snails-rb/dist[asset_pattern=snails-dist-*.tar.gz,version_prefix=rev-]'
snails new demo
```

The first command that needs the toolchain assembles the pinned compiler. See [Getting Started](manual/02-getting-started.md) for the full first-project flow.

## Manual

The manual is the product documentation. It lives in [`manual/`](manual/) and is written for people building an app.

**The Basics**

- [Welcome to Snails!](manual/01-welcome-to-snails.md)
- [Getting Started](manual/02-getting-started.md)
- [Snails CLI](manual/03-snails-cli.md)
- [Coming from Rails](manual/04-coming-from-rails.md)

**Building Your App**

- [Your App's Structure](manual/05-your-app-structure.md)
- [Routes and Controllers](manual/06-routes-and-controllers.md)
- [Database and Models](manual/07-database-and-models.md)
- [Migrations](manual/08-migrations.md)
- [Forms and Validation](manual/09-forms.md)
- [Email](manual/10-email.md)
- [Background Jobs](manual/11-background-jobs.md)
- [Logging](manual/12-logging.md)

**Operating**

- [Local Development](manual/13-local-development.md)
- [Testing](manual/14-testing.md)
- [Deploying](manual/15-deploying.md)
- [Updating Snails](manual/16-updating-snails.md)

**The Rest**

- [Troubleshooting](manual/17-troubleshooting.md)
- [FAQ](manual/18-faq.md)

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

`.github/workflows/ci.yml` is the pull-request gate: the Linux amd64 suite on sqlite. `platform-ci.yml` runs on main and adds PostgreSQL, macOS, arm64, and the app image. The scripts need a pinned spinel toolchain; `ci.yml` shows how it is installed.

## License

MIT. See [`LICENSE`](LICENSE).

`runtime/` began as a fork of the Spinel scaffold emit and has been substantially rewritten. The derived portions live in `runtime/action_controller/` and `runtime/action_dispatch/`; each carries the upstream notice in its `NOTICE` file. `runtime/tep/` follows tep's notice in `runtime/tep/NOTICE`. The rest of the runtime is snails' own work.
