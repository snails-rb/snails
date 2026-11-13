# Getting Started

This chapter takes you from nothing to a running Snails app: install the CLI, create a project, run it, and run its tests. A Snails project arrives ready to build, so there is no wiring to do first; the first `snails new` is the slowest step because it assembles the pinned compiler.

## Requirements

Snails runs on Linux amd64 with glibc 2.36 or newer (Debian 12, Ubuntu 24.04, Fedora), on Linux arm64, and on macOS for development. Windows runs through WSL. Alpine (musl) and native Windows are not supported.

The first `snails new` builds the pinned compiler from source when the machine has no install at that revision. The build runs on the host, so install the packages below before the first project.

### Linux

```sh
sudo apt-get install -y clang libclang-dev sqlite3 libsqlite3-dev libssl-dev libffi-dev libjemalloc-dev pkg-config
```

These are the Debian and Ubuntu package names; other distributions use the same packages under different names. Add `libpq-dev` for the PostgreSQL adapter. `git`, `make`, `curl`, and `tar` are also required, and the host needs time zone files (`tzdata`) because app boot resolves `Snails.time_zone =` against them.

### macOS

```sh
xcode-select --install
brew install openssl@3 jemalloc pkg-config
```

Run these commands before the first `snails new`. If OpenSSL is missing at build time, the compiler is built without the `openssl` package; the result is cached at the pinned revision, so fixing OpenSSL later does not rebuild it. For the PostgreSQL adapter, add `brew install libpq` and put its path on `PKG_CONFIG_PATH`; the test harness runs its disposable database in Docker Desktop unless you pass `PG_URL`.

```sh
export PATH="$(brew --prefix libpq)/bin:$PATH"
export PKG_CONFIG_PATH="$(brew --prefix libpq)/lib/pkgconfig:$PKG_CONFIG_PATH"
```

## Install the CLI

```sh
curl -fsSL https://raw.githubusercontent.com/snails-rb/snails/main/install.sh | bash
```

The installer puts `snails` on your `PATH` and keeps the release under `~/.local/share/snails`. If you manage tools with [mise](https://mise.jdx.dev/), install the same release as a tool instead:

```sh
mise use -g 'github:snails-rb/snails[asset_pattern=snails-dist-*.tar.gz,version_prefix=rev-]'
```

While the repository has only release candidates, add `prerelease=true` to that tool entry.

A project calls the CLI through its own `bin/` scripts most days. Run `snails` with no arguments to see every command it offers.

## Create a project

```sh
snails new myapp
cd myapp
```

`new` writes a small but complete app. It answers `GET /up`, carries a test harness, runs through `bin/dev` and `bin/test`, and records the runtime and compiler it builds with in `pins.toml`. You do not fetch or match versions by hand; the first command that needs the toolchain assembles the pinned one.

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

The first run compiles the app into a single native binary. Later runs reuse that build. The server stays in the foreground and writes to the terminal and to `tmp/development.log`:

```text
[snails] serving myapp on http://127.0.0.1:3000
[snails] log: tmp/development.log (append)
myapp (spinel) listening on http://0.0.0.0:3000, pid 212514
  one green thread per connection; OS workers: one per core (SPINEL_WORKERS=N to cap); processes: 1
```

Open http://localhost:3000/up and you get `{"status":"ok"}`. Every Snails app answers `/up`; deployment platforms use it to check that the app is healthy.

A plain project has no migrations. A scaffolded project has a baseline migration; `snails migrate load` applies it and writes the schema dump, so provision the database before the first boot:

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

That is the whole loop: edit, `bin/dev` to try it live, `bin/test` before you call it complete. Your controllers live in `app/controllers`, routes in `config/routes.rb`, and data in the database that `bin/dev` uses. A fresh app has no controllers; `GET /up` comes from the runtime.

[Your App's Structure](05-your-app-structure.md) describes the folder layout, and [Routes and Controllers](06-routes-and-controllers.md) begins the request path.
