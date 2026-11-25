# Troubleshooting

Start with the symptom. Each section below starts with a real error and gives the fix that unblocks it.

### My route table won't parse

`spinel could not parse it — Parse errors in 'config/routes.rb'` with `expected a ',' separator` means the entries in the route list have no commas — a newline isn't a separator:

```ruby
[
  get("/up", Snails::HealthController, :show),
  get("/posts", Api::PostsController, :index),   # commas between rows
]
```

### `:name is derived from more than one pattern`

Two hand-written entries want the same path helper name (`/posts` and `/posts/:id` both derive `posts`). Give one entry its own name with a `# as:` marker:

```ruby
get("/posts", Api::PostsController, :index),
get("/posts/:id", Api::PostsController, :show), # as: post
```

A `resources` entry can't carry the marker. Use a hand-written entry when the path helper name must differ. See [Routes and Controllers](06-routes-and-controllers.md).

### The compiler refuses my model's class methods

If the compiler refuses `create!` or `find_by` on your model with `unsupported call`, the model file isn't being loaded. Keep the model under `app/models/` and check that `gen/models.rb` holds the `# scan: models/**/*` spec — an empty region never loads a model. Run `bin/test` once so the list regenerates with your file in it.

### `Sqlx::Base model found but no schema file`

A model exists but `db/schema.sql` doesn't. If the table has no migration yet, write one under `db/migrate/` first. Run `snails migrate dump` to write the schema dump, then `snails migrate load` if the database isn't initialized yet.

### My parameter comes back nil

`params` is a hash keyed by strings — `params[:id]` is always nil, so the value never reaches your JSON. Use `params["id"]`.

### A missing required parameter returns 400

`ActionController::Params.require_key` raises `ParameterMissing` for an absent or blank value, and the framework turns it into `{"error":"bad_request"}`. If a blank string is a valid value for that field, use `str` or `provided` instead of `require_key`. See [Requests and Parameters](07-requests-and-parameters.md).

### A date, boolean, or JSON column raises while a record is built

`from_row` raises `ArgumentError` when a declared `datetime_columns`, `date_columns`, `boolean_columns`, or `json_columns` entry isn't in the projection. A hand-written narrower SELECT must declare the narrowed columns or override `from_row`. The built-in `created_at`/`updated_at` pair is the only exception. See [Columns and Types](11-columns-and-types.md).

### The `.expected` file is out of date

`bin/test` diffs every case file against its `.expected` sibling. If you changed what a test prints, update the `.expected` file in the same change. A failed load or boot names the kept server log path. `bin/test --verbose` prints the full log. See [Testing](24-testing.md).

### `SECRET_KEY_BASE is missing`

The app reads `Snails.app.secret_key_base` somewhere and the environment is unset. Set `SECRET_KEY_BASE` in `.env` (source it) or the platform's secret store. `snails doctor` shows the skip in development and the requirement in production. See [Configuration](16-configuration.md).

### `PG_URL is required`

`config/database.rb` selects the PostgreSQL adapter but the connection string is empty. Set `PG_URL`, or switch the require back to the SQLite backend. `bin/dev` starts a development container only when `PG_URL` is unset and the adapter is PostgreSQL.

### `unknown time zone`

`Snails.time_zone = "..."` received a name with no zone file. Use a vocabulary name (`"Seoul"`) or an IANA identifier (`"Asia/Seoul"`), and make sure `tzdata` is installed on the host. The typo raises at boot, not at the first request. See [Time, Dates, and JSON](17-time-dates-and-json.md).

### `Sqlx::Busy` or `Sqlx::ConnectionTimeout`

The database is under contention. `Sqlx::Busy` is a SQLite lock wait past `DATABASE_BUSY_TIMEOUT_MS`. `ConnectionTimeout` is a pool checkout past `DATABASE_POOL_TIMEOUT_MS` on PostgreSQL. Shorten the transaction or raise the timeout/pool for the load. `Sqlx::ConnectionFailed` means the session is gone. Retry the whole unit. See [Concurrency](23-concurrency.md) and [Error Handling](20-error-handling.md).

### A migration command refuses with `DB_OWNER="external"`

`pins.toml` declares the schema belongs to another system, so `load`, `apply`, and `dump` refuse to write DDL. Apply the change in the owning system and use `snails migrate check` to confirm the app sees the expected state. See [Deploying](25-deploying.md).

### A scheduled job raises `schedule needs a worker loop`

`ActiveJob.schedule` was called in a process with no worker loop — a test case, or an app that never started a server. Schedule it from a server action, or use `enqueue` when the work can run at the call site. See [Background Jobs](15-background-jobs.md).

### A cached value is missing in another process

`Snails.cache` is per process. A second server process or a container doesn't see the first one's entries. Put shared state in the database. See [Caching](18-caching.md).

### A JSON response is the object's string form

`render(json: record)` uses `record.as_json` when the record defines it. Otherwise the encoder falls back to `to_s`. Give the model an `as_json` that returns the payload format. See [Time, Dates, and JSON](17-time-dates-and-json.md).

### The first `snails new` stops in a compiler build

`snails new` downloads the pinned compiler. When no asset exists for your platform or revision, or the download fails, it falls back to a source build. A missing compiler, header, or `pkg-config` stops that build inside `make`. Install the packages under [Getting Started](02-getting-started.md#requirements) §If the prebuilt compiler is unavailable and run the command again.

The source build runs a smoke test of the required packages before caching. If OpenSSL or another package is missing, it stops and names the development packages. Install them and retry.

### The first build stops with `cc: not found`

The C compiler is missing. Install `build-essential` on Debian/Ubuntu or run `xcode-select --install` on macOS, then run `bin/dev` or `bin/test` again.

### The first build stops with a linker error

A linker error such as `cannot find -lssl` names the missing development package. The build links OpenSSL, the database client (SQLite or libpq), and jemalloc. Install the Linux or macOS packages under [Getting Started](02-getting-started.md#requirements) and run the build again.

On macOS, the build adds Homebrew's `pkg-config` and library directories for OpenSSL, jemalloc, libpq, and PostgreSQL, so the build needs no export.

For libpq, `brew install postgresql` is keg-only and includes the server, `psql`, `pg_dump`, and libpq. The `PATH` and `DYLD_FALLBACK_LIBRARY_PATH` exports in Getting Started point at its prefix. A client-only `libpq` install is the alternative when you connect to a server elsewhere.

When the symptom isn't here, run `snails doctor` first — it checks the pin, the toolchain, the database, and the local clients before you go looking further.
