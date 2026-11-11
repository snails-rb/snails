# Getting Started

This chapter takes you from nothing to a running Snails app: install the CLI, create a project, run it, and run its tests. It's short on purpose — a Snails project arrives ready to build, so there's no wiring to do first. The first build is the slowest part of the whole journey; after that, everything is fast.

## Install the CLI

Snails installs with one line:

```sh
curl -fsSL https://raw.githubusercontent.com/snails-rb/dist/main/install.sh | bash
```

It puts the `snails` command on your path and keeps the release it installed under `~/.local/share/snails`. If you manage your tools with [mise](https://mise.jdx.dev/), install the same release as a tool instead:

```sh
mise use -g 'github:snails-rb/dist[asset_pattern=snails-dist-*.tar.gz,version_prefix=rev-]'
```

Once a project exists you won't call `snails` much by hand — its work happens behind the project's own scripts. Run it with no arguments any time you want to see everything it can do.

## Create a project

```sh
snails new myapp
cd myapp
```

`new` gives you a small but complete app. It answers `GET /up`, has a test harness, runs through two scripts — `bin/dev` and `bin/test` — and records, in `pins.toml`, exactly which runtime and compiler it's built with. You don't fetch or match versions by hand; the first command that needs the toolchain assembles the pinned one.

If you'd rather start from a fuller example, `snails new demo --scaffold` adds a working posts-and-comments JSON API you can read end to end. And if your database is Postgres instead of the default sqlite, pass `--database=postgresql` — you'll need Docker for that.

## Run it

```sh
bin/dev
```

The first run compiles the app into a single native binary — and, the very first time only, assembles the pinned build tools too — then serves it at http://localhost:3000 in the foreground. The log streams to your terminal and to `tmp/development.log`.

Open http://localhost:3000/up and you'll get `{"status":"ok"}`. Every Snails app answers `/up`; it's what a deployment platform will watch to know your app is healthy. The development database (a sqlite file by default) lives under `storage/` and survives restarts, so you can leave data in there between sessions. If the app has migrations, provision it first with `snails migrate load` — `bin/dev` never creates, loads, or applies anything and stops with the command while the database is uninitialized or anything is pending. `Ctrl-C` stops the server.

## Run the tests

```sh
bin/test
```

This builds the app, boots it on a spare port, and runs the harness against the real HTTP server — no mocks. A fresh project has one case, the `/up` check:

```
ok   up_test.rb
1/1 passed
```

As your app grows you add cases next to it — each is a plain Ruby file under `harness/test/`.

## Where to go from here

That's the whole loop: edit, `bin/dev` to try it live, `bin/test` before you call it done. The app itself is ordinary code in the project folder — routes in `config/routes.rb`, your controllers in `app/controllers` (a fresh app has none; `GET /up` comes from the runtime), and your data in the database `bin/dev` is running.

The rest of the manual picks up from here, chapter by chapter. When your app needs to send mail, [Email](10-email.md) covers the whole path.
