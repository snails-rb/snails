# Getting Started

This chapter takes you from nothing to a running Snails app: install the CLI, create a project, run it, and run its tests. A Snails project arrives ready to build, so there is no wiring to do first; the first build is the slowest part of the journey.

## Install the CLI

```sh
curl -fsSL https://raw.githubusercontent.com/snails-rb/snails/main/install.sh | bash
```

The installer puts `snails` on your path and keeps the release under `~/.local/share/snails`. If you manage tools with [mise](https://mise.jdx.dev/), install the same release as a tool instead:

```sh
mise use -g 'github:snails-rb/snails[asset_pattern=snails-dist-*.tar.gz,version_prefix=rev-]'
```

A project calls the CLI through its own `bin/` scripts most days. Run `snails` with no arguments to see every command it offers.

## Create a project

```sh
snails new myapp
cd myapp
```

`new` writes a small but complete app. It answers `GET /up`, carries a test harness, runs through `bin/dev` and `bin/test`, and records in `pins.toml` which runtime and compiler it builds with. You do not fetch or match versions by hand; the first command that needs the toolchain assembles the pinned one.

```text
[snails] created myapp (GET /up)
  cd myapp
  bin/dev          start the development server
  bin/test         run the test suite
  bin/build-image  build the app image
  bin/compose      deploy with Docker Compose (compose.yml)
  database         sqlite (storage/development.sqlite3)
```

Pass `--scaffold` for a working posts-and-comments JSON API you can read end to end. Pass `--database=postgresql` to build against PostgreSQL instead of the default SQLite; that variant uses Docker for the development database.

```sh
snails new demo --scaffold
snails new demo --database=postgresql --scaffold
```

## Run it

```sh
bin/dev
```

The first run compiles the app into a single native binary and assembles the pinned build tools. Later runs reuse both. The server stays in the foreground and writes to the terminal and to `tmp/development.log`:

```text
[snails] serving myapp on http://127.0.0.1:3000
[snails] log: tmp/development.log (append)
myapp (spinel) listening on http://0.0.0.0:3000, pid 212514
  one green thread per connection; OS workers: one per core (SPINEL_WORKERS=N to cap); processes: 1
```

Open http://localhost:3000/up and you get `{"status":"ok"}`. Every Snails app answers `/up`; a deployment platform watches it to know the app is healthy.

A plain project has no migrations. A scaffolded project has a baseline migration and a schema dump, so provision it before the first boot:

```sh
snails migrate load
```

`bin/dev` never creates, loads, or applies anything. While the database is uninitialized or a migration is pending it stops before the build and prints the command that fixes it. `Ctrl-C` stops the server.

## Run the tests

```sh
bin/test
```

This builds the app, boots it on a spare port, and runs the harness against the real HTTP server — no mocks. A fresh project has one case file with two cases, the `/up` check and an unknown route's JSON 404:

```text
ok   up_test.rb
1/1 passed
```

The count is case files, not individual cases. As your app grows you add files beside that one under `harness/test/`.

## Where to go from here

That is the whole loop: edit, `bin/dev` to try it live, `bin/test` before you call it done. Your controllers live in `app/controllers` (a fresh app has none; `GET /up` comes from the runtime), routes in `config/routes.rb`, and data in the database `bin/dev` is running.

[Your App's Structure](05-your-app-structure.md) maps the folders, and [Routes and Controllers](06-routes-and-controllers.md) starts the request path.
