# Your App's Structure

A fresh project looks like this:

```text
.
├── app
├── bin
│   ├── build-binary
│   ├── build-image
│   ├── compose
│   ├── demo.rb
│   ├── dev
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
│   └── test.env
├── main.rb
├── pins.toml
└── spin.toml
```

Most days you touch three folders: `app/` for your controllers, models, forms, mailers, and jobs; `config/` for the files that shape the app (`routes.rb` first); and `harness/test/` for the tests that `bin/test` runs.

The rest is setup you rarely edit: `bin/` holds the scripts that run and build the app, `gen/` holds the generated require lists the app loads at boot, `deploy/` and `Dockerfile` describe how the image ships, and `main.rb`, `spin.toml`, and `pins.toml` pin the app together — what it is called, what the build needs, and which version of snails it uses.

When you need to change the database, you add files under `db/` — see [Migrations](08-migrations.md).

## Where the app sits

Snails works out which app you mean from where you stand. It recognizes two layouts: the one `snails new` creates, where a single folder is the whole app, and the one where the app sits in `src/` inside a repository.

### One folder, one app

`snails new myapp` gives you a folder that is a whole app. Its database settings and its `pins.toml` sit side by side:

```sh
tree -L 3 --prune -P 'pins.toml|database.rb' myapp
```

```
myapp
├── config
│   └── database.rb
└── pins.toml

2 directories, 2 files
```

Start anywhere inside and snails walks up until it finds the app:

```sh
cd myapp/config
snails migrate status
```

```
[snails] app root /tmp/manual2/myapp (auto-resolved)
[snails] 0 applied, 0 pending
```

The first line says where it landed. You don't get one when you're already standing in the app folder.

### The app in src/

A repository can keep its app one level down, in `src/`, so the repository root stays free for the rest of the project: deploy files, documentation, CI. `snails new repo/src` gives you that layout:

```sh
tree -L 3 --prune -P 'pins.toml|database.rb' repo
```

```
repo
└── src
    ├── config
    │   └── database.rb
    └── pins.toml

3 directories, 2 files
```

The app itself is unchanged, just one folder deeper. Start inside it and snails resolves it the same way:

```sh
cd repo/src/config
snails migrate status
```

```
[snails] app root /tmp/manual2/repo/src (auto-resolved)
[snails] 0 applied, 0 pending
```

From the repository root, snails doesn't look down. Finding an app below would mean picking one when there could be several, so it stops and tells you:

```
[snails] no app root at or above /tmp/manual2/repo (looked for config/database.rb) — pass --app DIR
```

Name the folder you are standing in and snails finds the app inside it:

```sh
snails migrate status --app .
```

```
[snails] 0 applied, 0 pending
```

### More than one app

A folder can hold several apps. Each one is complete and each keeps its own `pins.toml` next to its own `config/`. The file carries the app's name too, and snails uses that name for the development database and container, so two apps can't share one:

```sh
tree -L 3 --prune -P 'pins.toml|database.rb' apps
```

```
apps
├── billing
│   ├── config
│   │   └── database.rb
│   └── pins.toml
└── reports
    ├── config
    │   └── database.rb
    └── pins.toml

5 directories, 4 files
```

Stand inside either and it works as before:

```sh
cd apps/billing
snails migrate status
```

```
[snails] 0 applied, 0 pending
```

From the folder that holds both, snails won't pick one for you:

```
[snails] no app root at or above /tmp/manual2/apps (looked for config/database.rb) — pass --app DIR
```

Name the one you want:

```sh
snails migrate status --app billing
```

```
[snails] 0 applied, 0 pending
```

Commands that take a folder rather than `--app` work the same way: `snails sync billing`, run from `apps/`.

Back to the day-to-day loop in [Getting Started](02-getting-started.md).
