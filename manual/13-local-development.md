# Local Development

`bin/dev` builds the app and runs it on your machine with your development database.

## Start it

```text
[snails] pins ok (spinel=92e3f26be snails=d38ad49)
[snails] /tmp/tmp.g5AabIJpp7/demo snails-core in sync
build demo (up to date)
[snails] serving demo on http://127.0.0.1:3000
[snails] log: tmp/development.log (append)
demo (spinel) listening on http://0.0.0.0:3000, pid 212514
  one green thread per connection; OS workers: one per core (SPINEL_WORKERS=N to cap); processes: 1
```

The first lines check that your project matches the version of Snails it pins, the next one compiles, and the last two say where it listens and where the log goes (see [Logging](12-logging.md)).

## Change code, see it live

The server does not watch files — after you edit, stop it and run `bin/dev` again; the rebuild is cached, so only what changed is recompiled. When you are iterating on the code and the build is already fresh, `bin/dev --skip-build` serves the existing binary without the compile step.

`snails new` creates `storage/`; run `snails migrate load` before the first boot. `bin/dev` never creates, loads, or applies anything — while the database is uninitialized or a migration is pending it stops and prints the command. Keep `db/schema.sql` current so the tests build from the same schema the migrations produce.
