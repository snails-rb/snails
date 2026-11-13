# Troubleshooting

Start with the symptom. Each section below is a real error shape and the fix that unblocks it.

### A route row will not parse

`spinel could not parse it — Parse errors in 'config/routes.rb'` with `expected a ',' separator` means the rows in the route list have no commas — a newline is not a separator:

```ruby
[
  get("/up", Snails::HealthController, :show),
  get("/posts", Api::PostsController, :index),   # commas between rows
]
```

### `:name is derived from more than one pattern`

Two hand-written rows want the same helper name (`/posts` and `/posts/:id` both derive `posts`). Give one row its own name with a `# as:` marker:

```ruby
get("/posts", Api::PostsController, :index),
get("/posts/:id", Api::PostsController, :show), # as: post
```

A `resources` row cannot carry the marker; use a hand-written row when the helper name must differ. See [Routes and Controllers](06-routes-and-controllers.md).

### A model's class methods are refused at build time

If the compiler refuses `create!` or `find_by` on your model with `unsupported call`, the model file is not being loaded. Keep the model under `app/models/` and check that `gen/models.rb` carries the `# scan: models/**/*` spec — an empty region never loads a model. Run `bin/test` once so the list regenerates with your file in it.

### `Sqlx::Base model found but no schema file`

A model exists but `db/schema.sql` does not. Run `snails migrate dump` to write the schema dump, then `snails migrate load` if the database is not initialized yet. A plain project with no migrations has nothing to dump; add one or use `--scaffold`.

### A parameter comes back nil

`params` is a hash keyed by strings — `params[:id]` is always nil, so the value never reaches your JSON. Use `params["id"]`.

### A required parameter answers 400

`ActionController::Params.require_key` raises `ParameterMissing` for an absent or blank value, and the dispatcher turns it into `{"error":"bad_request"}`. If a blank string is a valid value for that field, use `str` or `provided` instead of `require_key`. See [Requests and Parameters](07-requests-and-parameters.md).

### A date, boolean, or JSON column raises during hydration

`from_row` raises `ArgumentError` when a declared `datetime_columns`, `date_columns`, `boolean_columns`, or `json_columns` entry is not in the projection. A hand-written narrower SELECT must declare the narrowed columns or override `from_row`. The built-in `created_at`/`updated_at` pair is the only exception. See [Columns and Types](11-columns-and-types.md).

### The test runner disagrees with your memory of a file

`bin/test` diffs every case file against its `.expected` sibling. If you changed what a test prints, update the `.expected` file in the same change. A failed load or boot names the kept server log path; `bin/test --verbose` prints the full log. See [Testing](24-testing.md).

### `SECRET_KEY_BASE is missing`

The app reads `Snails.app.secret_key_base` somewhere and the environment is unset. Set `SECRET_KEY_BASE` in `.env` (source it) or the platform's secret store. `snails doctor` shows the skip in development and the requirement in production. See [Configuration](16-configuration.md).

### `PG_URL is required`

`config/database.rb` selects the PostgreSQL adapter but the connection string is empty. Set `PG_URL`, or switch the require back to the SQLite backend. `bin/dev` starts a development container only when `PG_URL` is unset and the adapter is PostgreSQL.

### `unknown time zone`

`Snails.time_zone = "..."` received a name with no zone file. Use a vocabulary name (`"Seoul"`) or an IANA identifier (`"Asia/Seoul"`), and make sure `tzdata` is installed on the host. The typo raises at boot, not at the first request. See [Time, Dates, and JSON](17-time-dates-and-json.md).

### `Sqlx::Busy` or `Sqlx::ConnectionTimeout`

The database is under contention. `Sqlx::Busy` is a SQLite lock wait past `DATABASE_BUSY_TIMEOUT_MS`; `ConnectionTimeout` is a pool checkout past `DATABASE_POOL_TIMEOUT_MS` on PostgreSQL. Shorten the transaction or raise the timeout/pool for the load. `Sqlx::ConnectionFailed` means the session is gone; retry the whole unit. See [Concurrency](23-concurrency.md) and [Error Handling](20-error-handling.md).

### A migration command refuses with `DB_OWNER="external"`

`pins.toml` declares the schema belongs to another system, so `load`, `apply`, and `dump` refuse to write DDL. Apply the change in the owning system and use `snails migrate check` to confirm the app sees the expected state. See [Deploying](25-deploying.md).

### A scheduled job raises `schedule needs an executor`

`ActiveJob.schedule` was called in a process with no worker loop — a test case, or an app that never started a server. Schedule it from a server action, or use `enqueue` when the work can run at the call site. See [Background Jobs](15-background-jobs.md).

### A cached value is missing in another process

`Snails.cache` is per process. A second server process, a prefork child, or a container does not see the first one's entries. Put shared state in the database. See [Caching](18-caching.md).

### A JSON response is the object's string form

`render(json: record)` uses `record.as_json` when the record defines it; otherwise the encoder falls back to `to_s`. Give the model an `as_json` that returns the payload shape. See [Time, Dates, and JSON](17-time-dates-and-json.md).

### The first `snails new` stops in a compiler build

`snails new` assembles the pinned compiler before it writes the project, so a missing compiler, header, or `pkg-config` stops it inside `make`. Install the packages in [Getting Started](02-getting-started.md#requirements) and run the command again.

On macOS, if OpenSSL was missing during that first attempt, delete `.spinel/toolchain` and `~/.cache/snails/spinel/<rev>` first: the compiler built without the `openssl` package is cached at the pinned revision and is not rebuilt otherwise.

When the symptom is not here, run `snails doctor` first — it checks the pin, the toolchain, the database, and the local clients before you go looking further.
