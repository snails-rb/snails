# Configuration

A Snails app has two settings files with different jobs. `config/application.rb` holds values and readers — the app's name and version, plus the readers for the signing key and zone — and `config/environment.rb` holds the settings that depend on the mode: the time zone, the logger, the job queue adapter, the mail delivery class, and the boot hooks. The split keeps a value from changing behavior just because it was declared in the wrong file.

## Values live in config/application.rb

The generated file reopens `Snails::Application` and declares the app's name. Add a value by adding a reader:

```ruby
module Snails
  class Application
    def app_name
      "billing"
    end

    def version
      "1.4.2"
    end
  end
end
```

Read it through `Snails.app`:

```ruby
Snails.app.app_name       # "billing"
Snails.app.version        # "1.4.2"
```

The runtime supplies these defaults when an app declares none:

| Reader | Default | Notes |
|---|---|---|
| `app_name` | `"app"` | The server banner and container name. `snails new` fills this in. |
| `secret_key_base` | reads `SECRET_KEY_BASE` | Raises when unset or empty. Override when the key comes from a secret manager. |
| `time_zone` | `"UTC"` | Read-only; set the slot with `Snails.time_zone = "Seoul"` in `config/environment.rb`. |
| `version` | `nil` | No default. Declare it when the app has a version; a log record omits it otherwise. |
| `revision` | `ENV["REVISION"]`, then a `REVISION` file | Memoized for the process. There is no git fallback — a binary may run without the repository. |

Values are read at call time. A deployment can set `REVISION=...` without rebuilding; a process that reads it once keeps that value.

## Wiring lives in config/environment.rb

This file runs once at boot, after the runtime and every app file. The generated file sets the time zone, selects the process queue, and registers the test mail capture:

```ruby
Snails.time_zone = "UTC"

ActiveJob.queue_adapter = ActiveJob::ProcessQueue

ActionMailer::Base.delivery_method = ActionMailer::DeliveryLog if Snails.env.test?
```

A time-zone name is resolved and validated here. `"Seoul"` and `"Asia/Seoul"` both name the same zone; an unknown name raises at boot, so a typo cannot leave the process silently in UTC. Change this line rather than setting `TZ` in the environment — `TZ` is process-global and the runtime sets it from this slot.

The logger slots, the mail provider, and any boot override belong here too. The file is app-owned; `snails sync` never rewrites it.

## The boot chain

`main.rb` is the compile root. It requires `config/boot.rb`, which requires the runtime boot chain, and the chain ends by requiring the app's own files:

```text
main.rb
  config/boot.rb            require snails-core/boot/all
    runtime                   the framework
    config/database.rb        one adapter
    config/application.rb     app values
    config/routes.rb          route table
    config/codegen.rb         gen/* load lists
    config/environment.rb     app wiring
```

`config/database.rb` must require exactly one backend — sqlite or PostgreSQL — because the compiler keeps only the required adapter in the binary:

```ruby
require_relative "../snails-core/database/sqlite"
```

Switch adapters by changing that one line and generating the matching migration. `config/codegen.rb` is the app's load edges: it lists the `gen/*` require files, which the generator refreshes from the folders. Do not hand-maintain `gen/`; add the app file and let the next `bin/dev` or `bin/test` pick it up.

`Snails.root` is the app root as a path value. The server runs with the app root as its working directory, so it reads as `"."` and joins cleanly:

```ruby
"#{Snails.root}/tmp"                     # "./tmp"
Snails.root.join("tmp", "mail").to_s     # "./tmp/mail"
```

## Environment variables

The app does not read `.env`. Copy `.env.sample` to `.env`, uncomment what you need, and source it before the command:

```sh
cp .env.sample .env
set -a
. ./.env
set +a
```

| Variable | Applies to | Meaning |
|---|---|---|
| `SNAILS_ENV` | all | `development` (default), `test`, `staging`, `production` |
| `PORT` | server | Listen port; `--port` overrides it. Default `3000` |
| `WORKERS` | server | Accepted for multi-process operation; the server runs one process |
| `SPINEL_WORKERS` | server | Caps OS worker threads per process; the default is one per core |
| `SECRET_KEY_BASE` | all | Signing key read by `Snails.app.secret_key_base` |
| `REVISION` | all | Deployment identifier, ahead of a `REVISION` file |
| `DATABASE_PATH` | sqlite | Database file; relative paths resolve from the app root. Default `storage/development.sqlite3` |
| `DATABASE_POOL_SIZE` | sqlite, PostgreSQL | Connection count; default `8` |
| `DATABASE_BUSY_TIMEOUT_MS` | sqlite | How long one lock wait may take; default `5000` |
| `PG_URL` | PostgreSQL | libpq connection string; required by the PostgreSQL adapter |
| `DATABASE_POOL_TIMEOUT_MS` | PostgreSQL | Checkout wait before `ConnectionTimeout`; default `5000` |
| `DATABASE_IDLE_TIMEOUT_MS` | PostgreSQL | Idle connection lifetime; default `300000` |
| `DATABASE_MAX_LIFETIME_MS` | PostgreSQL | Connection lifetime; default `1800000` |
| `WORKER_CONCURRENCY` | server | Job worker threads; default `1` |
| `PG_CONTAINER_NAME`, `PG_PORT`, `PG_DATABASE` | local development | Overrides for the PostgreSQL dev container |
| `POSTGRES_PASSWORD` | compose | Password shared by `PG_URL` and the database container |
| `PUID`, `PGID` | compose | Container user ids, so the `./storage` mount stays yours |

`SNAILS_ENV` is read on first use. An out-of-vocabulary value makes every predicate false rather than raising, so a typo in the mode does not turn into a 500. `Snails.env.development?`, `.test?`, `.staging?`, and `.production?` are the predicates; `Snails.env.name` is the raw name. `Snails.env = "test"` swaps the slot in-process for a test or a console-style override.

`snails doctor` prints the settings it can check — the app name, the pin source, the mode, the database target, and whether the signing key is required — before the first boot.

Database connection details are covered in [Concurrency](23-concurrency.md). The app's `Snails.time_zone` slot is covered in [Time, Dates, and JSON](17-time-dates-and-json.md).
