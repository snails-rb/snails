# Getting Started

This chapter takes you from nothing to a running Snails app: install the CLI, create a project, run it, and run its tests. The first `snails new` downloads the pinned compiler for your platform; the first `bin/dev` or `bin/test` compiles your app.

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

`new` writes a small but complete app. It answers `GET /up`, carries a test harness, runs through `bin/dev` and `bin/test`, and records the runtime and compiler it builds with in `pins.toml`. You do not fetch or match versions by hand; the first command that needs the compiler downloads the pinned one. The download is about 13 MB and is cached per revision.

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

## Requirements

Snails runs on Linux amd64 with glibc 2.36 or newer (Debian 12, Ubuntu 24.04, Fedora), on Linux arm64, and on macOS 13 or newer (Apple Silicon and Intel). Windows runs through WSL. Alpine (musl) and native Windows are not supported.

The first `snails new` downloads the pinned compiler for Linux amd64/arm64 or macOS Apple Silicon/Intel. You do not need a C compiler or development headers for that step. The first `bin/dev` or `bin/test` compiles your app, so install the packages below before that command.

### Linux

```sh
sudo apt-get install -y build-essential libssl-dev libsqlite3-dev libjemalloc-dev sqlite3 tzdata
```

These are the Debian and Ubuntu package names; other distributions use the same packages under different names. `build-essential` provides the C compiler and linker; the runtime's logger links OpenSSL, the default database links SQLite, and the scaffold's allocator links jemalloc. `sqlite3` is the migration and test client, and `tzdata` provides the time zone files app boot reads.

For the PostgreSQL adapter, install the client and the libraries its native package links:

```sh
sudo apt-get install -y build-essential libssl-dev libpq-dev libffi-dev libjemalloc-dev postgresql-client tzdata
```

`curl` and `tar` are required by the installer. `git` is not required for the default project; third-party spin packages that fetch from git need it.

### macOS

```sh
xcode-select --install
brew install openssl@3 jemalloc pkg-config
```

The prebuilt macOS compiler is built against the standard Homebrew prefix — `/opt/homebrew` on Apple Silicon, `/usr/local` on Intel — and runs on macOS 13 or newer. If your Homebrew uses another prefix, the prebuilt compiler cannot find the OpenSSL it was built against; build it from source instead (below).

Xcode Command Line Tools provide the C compiler and linker for the app build. `openssl@3` is the OpenSSL the runtime links, `jemalloc` is the scaffold's allocator, and `pkg-config` lets spinel find Homebrew libraries outside the default search path.

For the PostgreSQL adapter, install the client and put its path on `PATH` and `PKG_CONFIG_PATH`. The test harness runs its disposable database in Docker Desktop unless you pass `PG_URL`.

```sh
brew install libpq
export PATH="$(brew --prefix libpq)/bin:$PATH"
export PKG_CONFIG_PATH="$(brew --prefix libpq)/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
```

### If the prebuilt compiler is unavailable

A platform or revision without a published asset falls back to a source build. The resolver reports the fallback and builds once per revision. Install the build tools and headers first.

On Linux:

```sh
sudo apt-get install -y build-essential git make curl patch pkg-config libssl-dev libffi-dev libsqlite3-dev libjemalloc-dev ruby
sudo apt-get install -y libpq-dev   # PostgreSQL adapter
sudo gem install prism:1.9.0 rbs:4.0.1 --no-document   # toolchain table generators
```

On macOS:

```sh
xcode-select --install
brew install openssl@3 jemalloc pkg-config libffi ruby
export PATH="$(brew --prefix ruby)/bin:$PATH"
gem install prism:1.9.0 rbs:4.0.1 --no-document
brew install libpq   # PostgreSQL adapter
export PKG_CONFIG_PATH="$(brew --prefix openssl@3)/lib/pkgconfig:$(brew --prefix jemalloc)/lib/pkgconfig:$(brew --prefix libpq)/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
export CPATH="$(brew --prefix openssl@3)/include:$(brew --prefix jemalloc)/include:${CPATH:-}"
export LIBRARY_PATH="$(brew --prefix openssl@3)/lib:$(brew --prefix jemalloc)/lib:$(brew --prefix libpq)/lib:${LIBRARY_PATH:-}"
```

The source build runs the same package smoke as the published asset. If openssl, ffi, json, or sqlite3 is missing, it stops before caching and names the development packages; install the headers (`openssl@3`, `libffi`, SQLite) and retry.

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
