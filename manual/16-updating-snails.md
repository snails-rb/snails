# Updating snails

When a new snails ships, you change one version line in `pins.toml` and run one command to pick it up. The pin is the whole upgrade: it decides which framework version your app builds against, which toolchain compiles it, and which release your tests verify.

## The pin file

```toml
# Core commit — the vendored snails-core/ must match it.
SNALS_REV="d38ad49afaad06587f85a4afdce4c846d68d4aaf"

# Build source — "pin" vendors SNALS_REV; "checkout" vendors the core
# checkout's working tree, so a build compiles it as it stands.
SNALS_SOURCE="pin"

# App identity — dev database and container names derive from it, never the
# directory name.
APP_NAME="demo"
```

`SNALS_REV` is the line that moves. `APP_NAME` never does — it is your app's name, not the framework's (see [Your App's Structure](05-your-app-structure.md)).

`SNALS_SOURCE` says where the framework copy in your app came from. A project created from an installed snails says `"pin"` and you leave it alone. A project created from a development checkout says `"checkout"`, which builds from that working tree as it stands — including changes you have not committed. Both build; the choice is about what your artifact contains, not whether the build is allowed (see [Deploying](15-deploying.md)).

## Check before you change

`snails pins check` reads the pin and tells you whether the project and the pin agree:

```text
[snails] pins ok (spinel=92e3f26be snails=d38ad49)
```

Exit code 0 means everything matches; a mismatch prints what disagrees and exits non-zero, so it works as a pre-flight on its own.

## Pick up a new version

1. Set `SNALS_REV` to the version you are moving to.
2. Run `snails sync` — it fetches that version into `snails-core/` and re-seeds the generated files.
3. Run `bin/test` — if the new version changed something you depend on, this is where you find out before you deploy.

`snails sync --check` reports the same comparison without writing anything — useful when you only want to know whether the project is in step with its pin:

```text
[snails] /tmp/tmp.g5AabIJpp7/demo snails-core in sync
```
