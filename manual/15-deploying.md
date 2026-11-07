# Deploy

A snails app is one native binary. The project builds it into a small container image, so you can run the same image on a laptop, a single server, or a container platform. You don't need the compiler on the machine that runs it.

## Build the image

```sh
bin/build-image
```

The first build is the slowest; later builds reuse the cache. The last two lines name the image and a run command:

```
[snails] image ready: myapp:local
[snails] next: docker run --rm -p 3000:3000 -v app_storage:/snails/storage myapp:local
```

## Run it

```sh
docker run --rm -p 3000:3000 -v app_storage:/snails/storage myapp:local
```

Open http://localhost:3000/up and you get `{"status":"ok"}`. The named volume keeps the sqlite database between runs. For PostgreSQL, set `PG_URL` instead of the volume:

```sh
docker run --rm -p 3000:3000 -e PG_URL=postgres://... myapp:local
```

## Deploy to a single server

The project includes a `compose.yml` for a single host. The standard release is three commands: build the image, apply database changes, then start the app (and PostgreSQL when selected) on `127.0.0.1:3000`. Run them on the server. From your machine, connect first with `ssh you@server`, then go to the project directory. If the project is not on the server yet, copy it there first (for example with `rsync` or a `tar` stream over SSH) or clone it from your repository.

1. (PostgreSQL only) Set `POSTGRES_PASSWORD` in `.env` before the first start. PostgreSQL stores only the password from the volume's first initialization, so changing it after `up` disconnects the app — use a new volume, or run `ALTER USER` and update `.env` too. The value goes into `PG_URL` as-is, so use a URL-safe password (letters, digits, `-._~`); for other characters, set `PG_URL` separately with a percent-encoded password.

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

The app port stays on `127.0.0.1:3000`; Caddy is the only public entry point. The sqlite database lives in `./storage` on the host. While the app runs, back it up with `sqlite3 ./storage/production.sqlite3 ".backup backup.sqlite3"` (or `VACUUM INTO`); a plain directory copy is safe only after `bin/compose stop app`. For PostgreSQL, use `pg_dump`. If the app has database changes, apply them to the deployed database before you send traffic — see Update a deployment below.

## Update a deployment

If the app has database changes, run the same three commands on the server. Build the image first — the migration runner and the `db/migrate` files are inside the image, so running the migration before the build applies the previous image's files. Then apply the migrations, then start the new version. `app` in the command is the service name in `compose.yml` (the database service is `db`); `snails` is the runner on the image's PATH.

```sh
bin/compose build
bin/compose run --rm app snails migrate apply
bin/compose up -d --wait
```

If another system owns the database schema, skip the `migrate apply` command and apply the changes there instead.

The server never changes the schema on boot. A bare `snails migrate apply` on the host targets your development database instead of the deployed one, so always run it through compose.

## Other platforms

The image is a standard container image. On Fly.io, Cloud Run, Kubernetes, or a host with systemd, point the platform at the same `Dockerfile` and pass the same environment variables: `SNAILS_ENV=production`, `PORT=3000`, and either `DATABASE_PATH` (sqlite) or `PG_URL` (PostgreSQL). Use `GET /up` as the health check. Run `snails migrate apply` from the image in your platform's release or deploy step, before the new version receives traffic.

If you run the binary directly without a container, `bin/build-binary` writes `build/<app>`. Install the runtime libraries and time zone data on the host, and run it under a process supervisor such as systemd.
