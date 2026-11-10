# FAQ

### Where does the database file live?

Under `storage/` in your project — `bin/dev` creates it on the first run. `snails doctor` prints the exact path:

```text
ok    database target: /tmp/tmp.g5AabIJpp7/demo/storage/development.sqlite3
```

### Do I need to install a database server?

Not for development — SQLite is a file and nothing else to run. Production talks to PostgreSQL through the same models; you point the app at a server with its connection setting (see [Deploying](15-deploying.md)).

### Why does a command exit early?

Most `snails` commands check the pin first. When the project and its pin disagree, they stop and tell you the fix — run `snails sync` and try again. `snails doctor` shows every check at once when you want the whole picture.

### When do the generated files regenerate?

`bin/dev` and `bin/test` refresh `gen/` on every run — that is why a new controller or model needs no extra wiring. The files are yours to commit; the generators keep the lists in step with your folders.

### Can two apps live on one machine?

Yes — each folder is a complete app with its own `pins.toml`, and `APP_NAME` keeps their development databases and containers apart (see [Your App's Structure](05-your-app-structure.md)).

### What survives a restart?

Everything in the files: `storage/` keeps your data, `db/migrate/` keeps your history, and the tests keep passing. Jobs that were waiting in memory when a restart happens are gone — use a schedule (see [Background Jobs](11-background-jobs.md)) for work that must happen whether or not a process was up.

### Something broke after an update — how do I go back?

Set `SNALS_REV` in `pins.toml` back to the version you came from, run `snails sync`, and `bin/test` (see [Updating Snails](16-updating-snails.md)).

If a symptom has a specific face — an error line you can copy — [Troubleshooting](17-troubleshooting.md) lists the real ones with their fixes.
