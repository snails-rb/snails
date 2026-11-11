# Snails CLI

The `snails` command is your entry point for everything outside your app's own `bin/` scripts. It creates projects, generates files, checks that your setup is intact, migrates the database, and runs your tests — each command prints one line of what happened and nothing else until you ask.

## What it can do

Run it with no arguments and it prints every command, grouped by when you reach for them:

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

## Everyday commands

Once a project exists, most days start with your own scripts — `bin/dev` to run the server and `bin/test` to run the suite. The CLI itself comes out when you change the shape of the project.

`snails generate` adds the files a feature needs. Ask it with no arguments to see what it can make:

```text
Usage: snails generate <generator> [<app_root>]

Generate code into an app tree.

Generators:
  job_queue  Add the DB-backed job queue migration and wiring

Examples:
  snails generate job_queue
  snails g job_queue
```

`snails migrate status` tells you where the database stands — applied and pending migrations in one line:

```text
[snails] 0 applied, 0 pending
```

`snails doctor` checks the whole project — the CLI, the pin, the toolchain, the database — and tells you what needs attention before you start working:

```text
[snails] doctor: /tmp/tmp.g5AabIJpp7/demo
  ok    CLI v0.45.0 (rev d38ad49)
  ok    pins.toml (/tmp/tmp.g5AabIJpp7/demo/pins.toml)
  ok    pin declaration
  ok    APP_NAME: demo
  ok    SNAILS_ENV: development
  skip  SECRET_KEY_BASE (only required in production)
  ok    snails-core and toolchain
  ok    database adapter: sqlite
  ok    database target: /tmp/tmp.g5AabIJpp7/demo/storage/development.sqlite3
  ok    database directory is writable
  skip  database file not created yet (snails migrate load creates it)
  ok    sqlite3
  ok    compose.yml (docker available)
[snails] 11 ok, 0 warnings, 0 failed
```

A warning does not stop you — it names the command that repairs the state before the first boot.

## Getting help

Every command explains itself. `snails help <command>` prints the usage, the sub-commands, and the options:

```text
Usage: snails migrate <status|plan|apply|load|verify|check|dump> [--app DIR] [--database TARGET] [--verbose]

Manage schema migrations and database initialization.

Commands:
  status   Show applied and pending migrations
  plan     Print the SQL of pending migrations
  apply    Apply pending migrations in order
  load     Initialize the database: create it, load db/schema.sql, apply
           pending migrations, then refresh the snapshot
  verify   Check the committed snapshot against the migration files
  dump     Regenerate db/schema.sql (tables, indexes, views) from the
           migration files — the snapshot is generated output
  check    Exit 1 while the database is uninitialized or a migration is
           pending (read-only)
```

`snails --version` prints the release and the commit it was built from:

```text
snails v0.45.0 (rev d38ad49)
```
