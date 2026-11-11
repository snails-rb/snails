# FAQ

### Where does the database file live?

Under `storage/` in your project — `snails new` creates the folder, and `snails migrate load` creates the database file. `bin/dev` never creates, loads, or applies anything. `snails doctor` prints the exact path:

```text
ok    database target: /tmp/manual-demo/storage/development.sqlite3
```

A plain project with no migrations has no database file until a feature needs one.

### Do I need to install a database server?

Not for SQLite development — it is a file and nothing else to run. Production talks to PostgreSQL through the same models; you point the app at a server with `PG_URL` (see [Deploying](25-deploying.md)).

### Why does a command exit early?

Most `snails` commands check the pin first. When the project and its pin disagree, they stop and name the fix — run `snails sync` and try again. `snails doctor` shows every check at once when you want the whole picture.

### When do the generated files regenerate?

`bin/dev` and `bin/test` refresh `gen/` before every build — that is why a new controller or model needs no extra wiring. The files are yours to commit; the generators keep the lists in step with your folders. `gen/model_columns.rb` and `gen/route_helpers.rb` are generated outright; do not edit them.

### Can two apps live on one machine?

Yes — each folder is a complete app with its own `pins.toml`, and `APP_NAME` keeps their development databases and containers apart (see [Your App's Structure](05-your-app-structure.md)).

### What survives a restart?

Everything in the files: `storage/` keeps your data, `db/migrate/` keeps your history, and the tests keep passing. Jobs queued in the default process queue are gone — they live in memory. `ActiveJob::DatabaseQueue` stores each job as a database row, so it survives a restart and another process can drain it (see [Background Jobs](15-background-jobs.md)).

### Something broke after an update — how do I go back?

Set `SNALS_REV` in `pins.toml` back to the version you came from, restore the matching `SPINEL_REV`, run `snails sync`, and run `bin/test` (see [Updating Snails](26-updating-snails.md)).

### Can I use Rails gems?

No. Your app and the framework compile into one native binary; a gem that expects a Ruby runtime, a Bundler load path, or a native extension has no place in that graph. `spin.toml` declares the build needs, and the runtime's helpers are listed in [Ruby Helpers](19-ruby-helpers.md).

### Does Snails render HTML?

No. There is no view layer; every controller answers JSON, a redirect, or a status. If you need server-rendered pages, another framework is a better fit.

### How do I run one test file?

```sh
bin/test -- harness/test/posts_test.rb
```

The path is under `harness/`. An unknown path fails loudly rather than widening to the whole suite (see [Testing](24-testing.md)).

### Why is `params[:id]` nil?

`params` is String-keyed. Use `params["id"]`. The path capture is a String too; convert it for an integer column (see [Requests and Parameters](07-requests-and-parameters.md)).

### How do I change the app name?

`APP_NAME` in `pins.toml` names the development database and container; `config/application.rb` answers `Snails.app.app_name`, which the server banner and logs use. Change both when the app's identity changes, and use a fresh development database when the database name moves.

### Why is my JSON payload a string?

`render(json: record)` uses `as_json` when the record defines it; otherwise the encoder falls back to `to_s`. Define `as_json` on the model or render a Hash (see [Time, Dates, and JSON](17-time-dates-and-json.md)).

If a symptom has a specific face — an error line you can copy — [Troubleshooting](27-troubleshooting.md) lists the real ones with their fixes.
