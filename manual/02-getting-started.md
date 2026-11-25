# Getting Started

This chapter takes you from an empty directory to a running Snails app. You'll install the CLI, create a project, run it, and run its tests. The first `snails new` downloads the pinned compiler for your platform. The first `bin/dev` or `bin/test` compiles your app.

## Install the CLI

```sh
curl -fsSL https://raw.githubusercontent.com/snails-rb/snails/main/install.sh | bash
```

The installer puts `snails` on your `PATH` and keeps the release under `~/.local/share/snails`. If you manage tools with [mise](https://mise.jdx.dev/), install the same release as a tool instead:

```sh
mise use -g 'github:snails-rb/snails[asset_pattern=snails-dist-*.tar.gz,version_prefix=v]'
```

Most days you'll call the CLI through the project's `bin/` scripts. Run `snails` with no arguments to see every command it offers.

## Create a project

```sh
snails new myapp
cd myapp
```

`new` writes a small but complete app. It serves `GET /up`, ships with a test harness, runs through `bin/dev` and `bin/test`, and records the framework and compiler it builds with in `pins.toml`. You don't fetch or match versions by hand. The first command that needs the compiler downloads the pinned one. The download is about 13 MB and is cached per revision.

```text
[snails] created myapp (GET /up)
  cd myapp
  bin/dev          start the development server
  bin/test         run the test suite
  bin/build-image  build the app image
  bin/compose      deploy with Docker Compose (compose.yml)
  database         sqlite (storage/development.sqlite3)
```

Pass `--scaffold` to add the demo app: a posts-and-comments JSON API you can run, test, and read end to end. It is a reference implementation, not a base for your own app. Pass `--database=postgresql` to build against PostgreSQL instead of the default SQLite. That variant uses Docker or `PG_URL` for the development database.

```sh
snails new demo --scaffold
snails new demo --database=postgresql --scaffold
```

## Requirements

Snails runs on Linux amd64 with glibc 2.36 or newer (Debian 12, Ubuntu 24.04, Fedora), on Linux arm64, and on macOS 13 or newer (Apple Silicon and Intel). Windows runs through WSL. Alpine (musl) and native Windows aren't supported.

The first `snails new` downloads the pinned compiler for Linux amd64/arm64 or macOS Apple Silicon/Intel. You don't need a C compiler or development headers for that step. The first `bin/dev` or `bin/test` compiles your app, so install the packages below before that command.

### Linux

```sh
sudo apt-get install -y build-essential libssl-dev libsqlite3-dev libjemalloc-dev sqlite3 tzdata
```

These are the Debian and Ubuntu package names; other distributions use the same packages under different names. `build-essential` provides the C compiler and linker. The framework's logger links OpenSSL, the default database links SQLite, and the server allocator links jemalloc. `sqlite3` is the migration and test client, and `tzdata` provides the time zone files app boot reads.

For the PostgreSQL adapter, install the client and the libraries its native package links:

```sh
sudo apt-get install -y build-essential libssl-dev libpq-dev libffi-dev libjemalloc-dev postgresql-client tzdata
```

`curl` and `tar` are required by the installer. `git` isn't required for the default project. Third-party spin packages that fetch from git need it.

### macOS

```sh
xcode-select --install
brew install openssl jemalloc pkg-config
```

The prebuilt macOS compiler is built against Homebrew's `openssl`: 4.x on Apple Silicon, and currently 3.x on Intel. It runs on macOS 13 or newer. macOS keeps Homebrew's libraries and their `pkg-config` files outside the default search paths. `bin/test`, `bin/dev`, and `bin/build-binary` add the Homebrew directories for OpenSSL, jemalloc, libpq, and PostgreSQL before they compile. Keep `pkg-config` installed. No export is needed.

For PostgreSQL, the `postgresql` runtime (or the client-only `libpq`) still needs the `DYLD_FALLBACK_LIBRARY_PATH` below.

Xcode Command Line Tools provide the C compiler and linker for the app build. `jemalloc` is the server allocator.

For the PostgreSQL adapter, install PostgreSQL and put its path on `PATH` and `DYLD_FALLBACK_LIBRARY_PATH`. `brew install postgresql` installs the server, `psql`, `pg_dump`, and libpq. Homebrew keeps it keg-only, so the exports below make it visible. The CLI adds its `pkg-config` directory and library path on its own. Start the local server with `brew services start postgresql`, or point `PG_URL` at an existing server. The test harness uses Docker Desktop when `PG_URL` is unset. A local server or an existing PostgreSQL works through `PG_URL`.

```sh
brew install postgresql
brew services start postgresql
export PATH="$(brew --prefix postgresql)/bin:$PATH"
export DYLD_FALLBACK_LIBRARY_PATH="$(brew --prefix postgresql)/lib:${DYLD_FALLBACK_LIBRARY_PATH:-}"
createdb myapp_development
export PG_URL="postgres://$(whoami)@127.0.0.1:5432/myapp_development"
```

### If the prebuilt compiler is unavailable

A platform or revision without a published asset falls back to a source build. The CLI reports the fallback and builds once per revision. Install the build tools and headers first.

On Linux:

```sh
sudo apt-get install -y build-essential git make curl patch pkg-config libssl-dev libffi-dev libsqlite3-dev libjemalloc-dev ruby
sudo apt-get install -y libpq-dev   # PostgreSQL adapter
sudo gem install prism:1.9.0 rbs:4.0.1 --no-document   # toolchain table generators
```

On macOS:

```sh
xcode-select --install
brew install openssl jemalloc pkg-config libffi ruby
export PATH="$(brew --prefix ruby)/bin:$(brew --prefix postgresql)/bin:$PATH"
gem install prism:1.9.0 rbs:4.0.1 --no-document
brew install postgresql   # PostgreSQL adapter
export PKG_CONFIG_PATH="$(brew --prefix openssl)/lib/pkgconfig:$(brew --prefix jemalloc)/lib/pkgconfig:$(brew --prefix postgresql)/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
export CPATH="$(brew --prefix openssl)/include:$(brew --prefix jemalloc)/include:${CPATH:-}"
export LIBRARY_PATH="$(brew --prefix openssl)/lib:$(brew --prefix jemalloc)/lib:$(brew --prefix postgresql)/lib:${LIBRARY_PATH:-}"
export DYLD_FALLBACK_LIBRARY_PATH="$(brew --prefix openssl)/lib:$(brew --prefix jemalloc)/lib:$(brew --prefix postgresql)/lib:${DYLD_FALLBACK_LIBRARY_PATH:-}"
```

The source build runs the same smoke test of the required packages as the published asset. If openssl, ffi, json, or sqlite3 is missing, it stops before caching and names the development packages. Install the headers (`openssl`, `libffi`, SQLite) and retry.

## Run it

```sh
bin/dev
```

The first run compiles the app into a single native binary. Later runs reuse that build. The server stays in the foreground and writes to the terminal and to `tmp/development.log`:

```text
[snails] serving myapp on http://127.0.0.1:3000
[snails] log: tmp/development.log (append)
myapp (spinel) listening on http://0.0.0.0:3000, pid 212514
  one green thread per connection; OS workers: main + one per core (SPINEL_WORKERS=N sets the total); processes: 1
```

Open http://localhost:3000/up and you get `{"status":"ok"}`. Every Snails app responds to `/up`. Deployment platforms use it as a health check.

For a project with migrations, run `snails migrate load` before the first boot. A plain project has no migrations, so there is nothing to load. The demo app adds a baseline migration. `load` applies it and writes the schema dump:

```sh
snails migrate load
```

`bin/dev` never creates, loads, or applies anything. While the database is uninitialized or a migration is pending, it stops before the build and prints the command that fixes it. `Ctrl-C` stops the server.

## Run the tests

```sh
bin/test
```

This builds the app, boots it on a spare port, and runs the harness against the real HTTP server — no mocks. A fresh project has one case file with two cases, the `/up` check and an unknown route's JSON 404:

```text
ok   up_test.rb
1/1 passed
```

The count is case files, not individual cases. As your app grows, add files next to that one under `harness/test/`.

## Next chapters

Keep the loop short: edit, run `bin/dev` to try it live, and run `bin/test` before you call a change complete. Your controllers live in `app/controllers`, routes in `config/routes.rb`, and data in the database that `bin/dev` uses. A fresh app has no controllers. `GET /up` comes from the framework.

[Your App's Structure](05-your-app-structure.md) describes the folder layout, and [Routes and Controllers](06-routes-and-controllers.md) begins the request path.
