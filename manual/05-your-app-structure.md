# Your App's Structure

A fresh project is small. Most of the tree is setup you touch once; the day-to-day folders are `app/`, `config/`, and `harness/test/`.

```text
.
├── app
├── bin
│   ├── build-binary
│   ├── build-image
│   ├── compose
│   ├── dev
│   ├── myapp.rb
│   └── test
├── compose.yml
├── config
│   ├── application.rb
│   ├── boot.rb
│   ├── codegen.rb
│   ├── database.rb
│   ├── environment.rb
│   └── routes.rb
├── deploy
│   └── Caddyfile
├── Dockerfile
├── .dockerignore
├── .env.sample
├── gen
│   ├── controllers.rb
│   ├── forms.rb
│   ├── helpers.rb
│   ├── jobs.rb
│   ├── lib.rb
│   ├── mailers.rb
│   ├── model_columns.rb
│   ├── models.rb
│   ├── route_helpers.rb
│   └── services.rb
├── harness
│   ├── boot.rb
│   ├── test
│   │   ├── up_test.rb
│   │   └── up_test.rb.expected
│   └── test.env
├── main.rb
├── pins.toml
└── spin.toml
```

## The folders you edit

- `app/` holds your controllers, models, forms, mailers, jobs, services, helpers, and shared lib classes. A fresh project starts with an empty folder; `--scaffold` fills it with the posts-and-comments example. `app/services/` is for plain classes that wrap a domain operation; `app/helpers/` is for modules shared by controllers; `app/lib/` is for shared modules and plain classes. All three load automatically and have no framework base class.
- `config/` shapes the app. `routes.rb` is the route table; `application.rb` holds values; `environment.rb` holds mode-dependent wiring; `database.rb` selects the adapter; `boot.rb` and `codegen.rb` decide what loads.
- `harness/test/` holds one plain Ruby file per case file, with a `.expected` sibling. `bin/test` runs them against a real server.

## The files that pin the app together

- `main.rb` is the compile root. It requires `config/boot.rb`, which starts the runtime and ends at the app's own files.
- `pins.toml` records the runtime release and the compiler revision. The first command that needs the toolchain assembles the one this file names.
- `spin.toml` is the build manifest. It names the allocator and any build-level settings the compiler needs.
- `compose.yml` is the single-host deployment file. `Dockerfile` builds the image; `deploy/Caddyfile` is the optional TLS proxy.
- `.env.sample` is a template for environment variables, not configuration. Copy it to `.env` and source it; the app does not read the file itself.
- `.dockerignore` keeps the build context small. `storage/` holds the SQLite database and is gitignored.

## The generated files

`gen/` is build output. The require-list files carry a `# scan:` spec and a literal list for one app folder; `snails` refreshes them before every build. `gen/route_helpers.rb` and `gen/model_columns.rb` are generated outright from the route table and the schema. Do not edit any of them by hand — a file added under `app/` appears after the next `bin/dev` or `bin/test`.

`snails-core/` and `.spinel/` are local state assembled by sync: the vendored runtime and the pinned compiler. Both are gitignored, so a fresh clone rebuilds them on the first command that needs them.

The exception is a placeholder file in a fresh project. `gen/model_columns.rb` stays a stub until a schema exists, and the first build tells you to run `snails migrate dump` when a model needs it.

`harness/build/` is also generated and gitignored. It holds the compiled test bundle and the schema loader cache.

A scaffolded project adds `db/`:

```text
db
├── migrate
│   └── 20261111210824_baseline.sql
└── schema.sql
```

`db/migrate/` is the migration history; `db/schema.sql` is the generated schema dump the test harness loads. Both are covered in [Migrations](12-migrations.md).

## Where the app sits

Snails works out which app you mean from where you stand. It recognizes two layouts: the one `snails new` creates, where a single folder is the whole app, and the one where the app sits in `src/` inside a repository.

### One folder, one app

`snails new myapp` gives you a folder that is a whole app. Its database settings and its `pins.toml` sit side by side:

```sh
tree -L 3 --prune -P 'pins.toml|database.rb' myapp
```

```text
myapp
├── config
│   └── database.rb
└── pins.toml

2 directories, 2 files
```

Start anywhere inside and Snails walks up until it finds the app:

```sh
cd myapp/config
snails migrate status
```

```text
[snails] app root /tmp/manual2/myapp (auto-resolved)
[snails] 0 applied, 0 pending
```

The first line says where it landed. You don't get one when you are already standing in the app folder.

### The app in src/

A repository can keep its app one level down, in `src/`, so the repository root stays free for deploy files, documentation, and CI. `snails new repo/src` gives you that layout:

```sh
tree -L 3 --prune -P 'pins.toml|database.rb' repo
```

```text
repo
└── src
    ├── config
    │   └── database.rb
    └── pins.toml

3 directories, 2 files
```

The app itself is unchanged, just one folder deeper. Start inside it and Snails resolves it the same way.

From the repository root, Snails does not look down. Finding an app below would mean choosing one when there could be several:

```text
[snails] no app root at or above /tmp/manual2/repo (looked for config/database.rb) — pass --app DIR
```

Name the folder you are standing in and Snails finds the app inside it:

```sh
snails migrate status --app .
```

### More than one app

A folder can hold several apps. Each one is complete and keeps its own `pins.toml` next to its own `config/`. The file carries the app's name too, and Snails uses that name for the development database and container:

```text
apps
├── billing
│   ├── config
│   │   └── database.rb
│   └── pins.toml
└── reports
    ├── config
    │   └── database.rb
    └── pins.toml
```

Stand inside either and it works as before. From the folder that holds both, name the one you want:

```sh
snails migrate status --app billing
```

Commands that take a folder rather than `--app` work the same way: `snails sync billing`, run from `apps/`.

Back to the loop in [Getting Started](02-getting-started.md).
