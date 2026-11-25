# Your App's Structure

A fresh project is small. Most of the tree is setup you touch once. The day-to-day folders are `app/`, `config/`, and `harness/test/`.

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

- `app/` holds your controllers, models, forms, mailers, jobs, services, helpers, and shared lib classes. `app/` starts empty. `--scaffold` fills it with the posts-and-comments demo app. `app/services/` is for plain classes that wrap a domain operation. `app/helpers/` is for modules shared by controllers. `app/lib/` is for shared modules and plain classes. All three load automatically and have no framework base class.
- `config/` defines the app. `routes.rb` is the route table. `application.rb` holds values, `environment.rb` holds mode-dependent wiring, and `database.rb` selects the adapter. `boot.rb` and `codegen.rb` decide what loads.
- `harness/test/` holds plain Ruby case files, each with a `.expected` sibling. `bin/test` runs them against a real server.

## The files that tie the app together

- `main.rb` is the entry point. It requires `config/boot.rb`, which starts the framework and loads the app's own files at the end of the chain.
- `pins.toml` records the framework release and the compiler revision. The first command that needs the toolchain installs the pinned compiler.
- `spin.toml` is the build manifest. It names the allocator and any build-level settings the compiler needs.
- `compose.yml` is the single-host deployment file. `Dockerfile` builds the image, and `deploy/Caddyfile` is the optional TLS proxy.
- `.env.sample` is a template for environment variables, not configuration. Copy it to `.env` and source it. The app doesn't read the file itself.
- `.dockerignore` keeps the build context small. `storage/` holds the SQLite database and is gitignored.

## The generated files

`gen/` holds generated files. The require files hold a `# scan:` spec and a literal list of the files in one app folder. `snails` refreshes them before every build. `gen/route_helpers.rb` and `gen/model_columns.rb` are generated from the route table and the schema. Don't edit any of them by hand — a file added under `app/` appears after the next `bin/dev` or `bin/test`.

`snails-core/` and `.spinel/` hold the framework copy and the pinned compiler. `snails sync` creates both, and both are gitignored, so a fresh clone rebuilds them on the first command that needs them.

`gen/model_columns.rb` is a stub in a fresh project until a schema exists. The first build tells you to run `snails migrate dump` when a model needs it.

`harness/build/` is also generated and gitignored. It holds the compiled test bundle and the schema loader cache.

The demo app adds `db/` with its baseline migration. After `snails migrate load`, it looks like this:

```text
db
├── migrate
│   └── 20261111210824_baseline.sql
└── schema.sql
```

`db/migrate/` is the migration history. `db/schema.sql` is the generated schema dump the test harness loads. Any app that uses migrations has a `db/` directory. The demo app's baseline is its own posts and comments schema, and a plain app starts without it. Both are covered in [Migrations](12-migrations.md).

## Where the app sits

Snails works out which app you mean from the directory you are in. It recognizes two layouts: the one `snails new` creates, where a single folder is the whole app, and the one where the app sits in `src/` inside a repository.

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

The first line says where it landed. Snails omits the line when you're already in the app folder.

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

The app itself is unchanged. It's just one folder deeper. Start inside it and Snails resolves it the same way.

From the repository root, Snails doesn't look down. Finding an app below would mean choosing one when there could be several:

```text
[snails] no app root at or above /tmp/manual2/repo (looked for config/database.rb) — pass --app DIR
```

Name the folder you are in and Snails finds the app inside it:

```sh
snails migrate status --app .
```

### More than one app

A folder can hold several apps. Each one is complete and keeps its own `pins.toml` next to its own `config/`. The file records the app's name too, and Snails uses that name for the development database and container:

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

Work from inside either app and the command behaves as before. From the folder that holds both, name the one you want:

```sh
snails migrate status --app billing
```

Commands that take a folder rather than `--app` work the same way: `snails sync billing`, run from `apps/`.

The edit/run/test loop is in [Getting Started](02-getting-started.md).
