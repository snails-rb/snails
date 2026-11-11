# Deploying

A Snails app is one native binary. The project builds it into a small container image, so the same image runs on a laptop, a single server, or a container platform. The machine that runs it does not need the compiler.

## Build the image

```sh
bin/build-image
```

The first build is the slowest; later builds reuse the cache. The last lines name the image and a run command:

```text
[snails] image ready: myapp:local
[snails] next: docker run --rm -p 3000:3000 -v app_storage:/snails/storage myapp:local
```

## Run it

```sh
docker run --rm -p 3000:3000 -v app_storage:/snails/storage myapp:local
```

Open http://localhost:3000/up and you get `{"status":"ok"}`. The named volume keeps the SQLite database between runs. For PostgreSQL, pass the connection string instead of the volume:

```sh
docker run --rm -p 3000:3000 -e PG_URL=postgres://... myapp:local
```

The runtime needs the database client library, `tzdata`, and the binary's dynamic libraries. The generated `Dockerfile` installs them; a host binary needs the same packages on the host.

## Deploy to a single server

The project includes a `compose.yml` for one host. The standard release is three commands, run on the server: build the image, apply database changes, then start the app (and PostgreSQL when selected) on `127.0.0.1:3000`.

1. (PostgreSQL only) Set `POSTGRES_PASSWORD` in `.env` before the first start. PostgreSQL keeps the first volume's password, so changing it after `up` disconnects the app — use a new volume, or run `ALTER USER` and update `.env` too. The value goes into `PG_URL` as-is, so use a URL-safe password (letters, digits, `-._~`); for other characters, set `PG_URL` separately with a percent-encoded password.

2. Release it:

   ```sh
   bin/compose build
   bin/compose run --rm app snails migrate apply
   bin/compose up -d --wait
   ```

   Keep the order. The build puts the migration runner and the `db/migrate` files into the image, `apply` applies them to the deployed database, and `up -d --wait` starts the app and waits for its health check. If `apply` fails, do not run `up`.

3. On the server, check that `curl http://127.0.0.1:3000/up` returns `{"status":"ok"}`.

4. For a public TLS host, replace `:80` in `deploy/Caddyfile` with your domain and start the proxy profile:

   ```sh
   bin/compose --profile proxy up -d
   ```

5. Open `https://<your-domain>/up`.

The app port stays on `127.0.0.1:3000`; Caddy is the only public entry point. The SQLite database lives in `./storage` on the host. While the app runs, back it up with `sqlite3 ./storage/production.sqlite3 ".backup backup.sqlite3"` (or `VACUUM INTO`); a plain directory copy is safe only after `bin/compose stop app`. For PostgreSQL, use `pg_dump`.

## Update a deployment

If the app has database changes, run the same three commands on the server. Build first — the migration runner and the `db/migrate` files are inside the image, so running a migration before the build applies the previous image's files. Then apply, then start the new version. `app` is the service name in `compose.yml`; `snails` is the runner on the image's `PATH`.

```sh
bin/compose build
bin/compose run --rm app snails migrate apply
bin/compose up -d --wait
```

If another system owns the database schema, set `DB_OWNER="external"` in `pins.toml` and skip the migration command; apply the change in the owning system. The migration commands refuse to write DDL when that pin is set, and `check` reports the expected state instead.

The server never changes the schema on boot. A bare `snails migrate apply` on the host targets the development database, not the deployed one, so run it through compose.

## Environment

The container needs these settings. The generated `compose.yml` and `Dockerfile` fill in the mode, the port, and the database target:

| Variable | Value |
|---|---|
| `SNAILS_ENV` | `production` |
| `PORT` | `3000` |
| `DATABASE_PATH` | SQLite file inside the container, or leave unset with `PG_URL` |
| `PG_URL` | PostgreSQL connection string, when that adapter is selected |
| `SECRET_KEY_BASE` | Required when the app signs tokens; generate with `openssl rand -hex 64` |
| `REVISION` | Optional deployment identifier; a `REVISION` file works too |

A deployment secret belongs in the platform's secret store or the untracked `.env`, never in `compose.yml` or the image. `POSTGRES_PASSWORD`, `PUID`, and `PGID` are the compose-specific values; see [Configuration](16-configuration.md) for the complete list.

## Other platforms

The image is a standard container image. On Fly.io, Cloud Run, Kubernetes, or a host with systemd, point the platform at the same `Dockerfile` and pass the same environment variables. Use `GET /up` as the health check. Run `snails migrate apply` from the image in the platform's release or deploy step, before the new version receives traffic.

`bin/build-binary` writes `build/<app>` for a host that runs the binary directly. Install the runtime libraries and time zone data, and run it under a supervisor such as systemd. The binary starts one process; run multiple copies or containers when you need more capacity. [Concurrency](23-concurrency.md) covers the process model.

[Updating Snails](26-updating-snails.md) covers a framework bump and its rebuild.
