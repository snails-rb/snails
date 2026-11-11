# Local Development

`bin/dev` builds the app and serves it on your machine with the development database. It is the foreground loop: the terminal holds the log, `Ctrl-C` stops the server, and the next run picks up your edits.

## Start it

```text
[snails] pins ok (spinel=858dde41b snails=v0.48.0)
[snails] /tmp/manual-demo/.spinel/toolchain in sync (spinel 858dde41b)
[snails] /tmp/manual-demo snails-core in sync
build manual-demo (up to date)
[snails] serving manual-demo on http://127.0.0.1:3000
[snails] log: tmp/development.log (append)
manual-demo (spinel) listening on http://0.0.0.0:3000, pid 74898
  one green thread per connection; OS workers: one per core (SPINEL_WORKERS=N to cap); processes: 1
```

The first lines check the pin, sync the vendored runtime, and compile. The next two say where it listens and where the log goes. [Logging](21-logging.md) covers the record format.

The server does not watch files. After an edit, stop it and run `bin/dev` again; the rebuild is cached, so only what changed is recompiled. When the build is already fresh and you only want to restart the process, `bin/dev --skip-build` serves the existing binary.

`bin/dev --fresh` recreates the development database first. Use it when an experiment has left rows you do not want; it is not a migration command.

## The database

`snails new` creates `storage/` for a SQLite app. A scaffolded project has a baseline migration, so run `snails migrate load` before the first boot:

```sh
snails migrate load
```

`bin/dev` never creates, loads, or applies anything. While the database is uninitialized or a migration is pending, it stops before the build and prints the command that fixes it. `--verbose` lists the pending labels and the full repair command.

With the PostgreSQL adapter, `bin/dev` starts a development container named from `APP_NAME` unless `PG_URL` names a database to use directly. `PG_CONTAINER_NAME`, `PG_PORT`, and `PG_DATABASE` override the container settings. [Configuration](16-configuration.md) lists the variables.

## Iterating on the app

The compile is incremental. A change to a controller, model, form, job, or mailer is recompiled on the next run; a new file is added to `gen/` by the generator step before the build. There is no autoload and no file watcher, so a missing `require` is a build error, not a silent runtime miss.

`bin/test` runs the same build and serves the harness against a separate, throwaway database. Use it as the check before you call a change done; `bin/dev` is for seeing the response yourself. [Testing](24-testing.md) covers the harness.

## Running from a checkout

The `bin/` wrappers resolve the CLI without a machine-specific path: `SNAILS_DIR` wins when set, otherwise `snails` on `PATH`. When you are developing the framework itself, point `SNAILS_DIR` at the checkout so the project uses that CLI and its pinned toolchain:

```sh
SNAILS_DIR=/path/to/snails bin/dev
```

Without `SNAILS_DIR`, the wrapper uses the installed release. A project created from a checkout records `SNALS_SOURCE="checkout"` in `pins.toml`, so its runtime comes from that working tree; a project created from a release records `"pin"` and syncs the published release. [Updating Snails](26-updating-snails.md) covers the pin.

[Concurrency](23-concurrency.md) explains the server's green threads, OS workers, and database pool.
