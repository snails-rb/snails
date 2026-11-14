# Snails CLI

`snails` is the entry point for everything outside your app's own `bin/` scripts. It creates projects, generates files, checks the setup, migrates the database, syncs the pinned runtime, and builds images or a host binary. Each command prints a one-line summary unless you ask for help or more detail.

## What it can do

Run it with no arguments to see the commands grouped by when you reach for them:

```text
usage: snails <command> [options]

Common
  new           Create a project
  generate      Generate code (g)
  migrate       Manage schema migrations
  sync          Update the vendored runtime

Project
  pins          Check pin declarations or print the pins file
  doctor        Check the project and toolchain

Build and deploy
  build-image   Build the app image
  build-binary  Build the native binary on this host
  compose       Run Docker Compose

Toolchain
  exec          Run a command from the pinned toolchain
  install-shim  Install spin/spinel PATH shims

Help
  help [COMMAND]  Show help for a command
  version         Show the CLI version

Inside a project, bin/dev runs the server and bin/test runs the test suite.
Run 'snails help --all' for internal commands.
```

`snails help --all` adds the commands the build, CI, and generated `bin/` scripts use: `harness`, `verify-pin`, `verify-pins`, `pins-path`, `verify-scaffold`, and the `gen-*` generators. Those are implementation surfaces; you normally reach them through `bin/dev`, `bin/test`, or `snails sync`.

## Create a project

```sh
snails new myapp
snails new demo --scaffold
snails new demo --database=postgresql --scaffold
```

`new` copies the project template, vendors the pinned runtime, seeds the harness, and prints the next commands. `--scaffold` overlays the posts-and-comments example; `--database` selects sqlite or PostgreSQL.

## Everyday commands

`snails generate` adds the files a feature needs. `job_queue` is the generator that ships:

```text
Usage: snails generate <generator> [<app_root>]

Generate code into an app tree.

Generators:
  job_queue  Add the DB-backed job queue migration and wiring

Examples:
  snails generate job_queue
  snails g job_queue
```

`snails migrate status` shows where the database stands:

```text
[snails] 0 applied, 0 pending
```

`snails migrate` handles the rest of the schema flow; `snails help migrate` prints the command list and the `--app`/`--database` options.

`snails pins check` reads `pins.toml` and confirms the runtime and toolchain pair:

```text
[snails] pins ok (spinel=858dde41b snails=v0.48.0)
```

`snails pins path` prints the nearest pins file. `snails sync` vendors the runtime and toolchain declared by that file; `snails sync --check` reports whether the tree is in step without writing.

## Doctor

`snails doctor` checks the whole project and names what needs attention before the first boot:

```text
[snails] doctor: /tmp/manual-demo
  ok    CLI v1.0.0-rc.1 (rev c5fc693)
  ok    pins.toml (/tmp/manual-demo/pins.toml)
  ok    pin declaration
  ok    APP_NAME: manual-demo
  ok    SNALS_SOURCE: pin
  ok    SNAILS_ENV: development
  skip  SECRET_KEY_BASE (only required in production)
  ok    snails-core and toolchain
  ok    database adapter: sqlite
  ok    database target: /tmp/manual-demo/storage/development.sqlite3
  ok    database directory is writable
  ok    database file is readable
  ok    sqlite3
  ok    compose.yml (docker available)
[snails] 13 ok, 0 warning, 0 failed
```

A skipped check is not a failure; `SECRET_KEY_BASE` is required only when the app signs values. A warning names the command that repairs the state. Exit code 1 means at least one check failed.

## Build and deploy

```sh
snails build-binary     # host binary at build/<app>
snails build-image      # container image from the project Dockerfile
snails compose -- up -d # Docker Compose through the project's wrapper
```

The project's `bin/build-binary`, `bin/build-image`, and `bin/compose` wrappers call the same engines with the project root already filled in. They are the commands to use day to day; [Deploying](25-deploying.md) covers the image and Compose recipes.

`snails exec` runs a command from the pinned toolchain, and `snails install-shim` writes `spin`/`spinel` shims that delegate to it. The shims make a pinned tree use its own compiler without a global install.

## Getting help

`snails help <command>` prints the usage, subcommands, and options:

```text
Usage: snails migrate <status|apply|load|verify|check|dump> [--app DIR] [--database TARGET] [--verbose]

Manage schema migrations and database initialization.

Commands:
  status   Show applied and pending migrations
  apply    Apply pending migrations in order
  load     Initialize the database: create it, load db/schema.sql, apply
           pending migrations, then refresh the schema dump
  verify   Check the committed schema dump against the migration files
  dump     Regenerate db/schema.sql (tables, indexes, views) from the
           migration files — the schema dump is generated output
  check    Exit 1 while the database is uninitialized or a migration is
           pending (read-only)
```

`snails --version` prints the release and the commit it was built from:

```text
snails v0.48.0 (rev c59adfa)
```

[Local Development](22-local-development.md) covers the scripts around the CLI; [Updating Snails](26-updating-snails.md) covers the pin and `sync`.
