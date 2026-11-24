# Updating Snails

When a new Snails ships, you change the version line in `pins.toml` and run one command to pick it up. The pin decides which framework version your app builds against, which compiler compiles it, and which release your tests verify.

## The pin file

```toml
# Framework pin — a release version (vX.Y.Z), or a full commit for an edge pin.
# The snails-core/ copy must match it.
SNALS_REV="vX.Y.Z"

# Compiler pin — the revision this framework release was verified with.
SPINEL_REV="<spinel-rev>"

# Build source — "pin" copies SNALS_REV; "checkout" copies the framework
# checkout's working tree, so a build compiles it as it stands.
SNALS_SOURCE="pin"

# App identity — dev database and container names derive from it, never the
# directory name.
APP_NAME="demo"
```

Replace `vX.Y.Z` and `<spinel-rev>` with the release and compiler revision you pin. `SNALS_REV` is the line that normally moves. `SPINEL_REV` is the compiler revision the framework release was verified with; a release that changes its compiler declares a new value, and you update that line to match. `snails pins check` validates the pair and names the expected value when the two disagree.

`APP_NAME` never moves — it is your app's name, not the framework's (see [Your App's Structure](05-your-app-structure.md)).

`SNALS_SOURCE` says where the framework copy in your app came from. A project created from an installed Snails says `"pin"` and you leave it alone. A project created from a development checkout says `"checkout"`, which builds from that working tree as it stands — including changes you haven't committed. Both build; the choice is about what your artifact contains, not whether the build is allowed.

## Check before you change

`snails pins check` reads the pin and tells you whether the project and the pin agree:

```text
[snails] pins ok
```

Exit code 0 means everything matches; a mismatch prints what disagrees and exits non-zero, so it works as a pre-flight on its own. `snails pins path` prints the file it read.

## Pick up a new version

1. Set `SNALS_REV` to the version you are moving to.
2. If the release declares a new compiler revision, set `SPINEL_REV` to that value.
3. Run `snails sync` — it fetches the framework into `snails-core/`, downloads or reuses the pinned compiler, and refreshes the files under `gen/`.
4. Run `snails pins check` and `bin/test`. The check catches a mismatched pair; the test suite catches a change your app depends on.

`snails sync --check` reports the same comparison without writing anything:

```text
[snails] /tmp/manual-demo/.spinel/toolchain in sync
[snails] /tmp/manual-demo snails-core in sync
```

A project on an edge pin (`SNALS_REV` is a full commit) resolves that commit from the checkout or the published dist. An installed release resolves a `vX.Y.Z` pin through the release tagged with that version.

Keep the CLI at or above the version you pin. When the release is newer than the CLI, run the install command from the README first, then set `SNALS_REV`.

## Go back

Set `SNALS_REV` back to the version you came from, restore the matching `SPINEL_REV`, run `snails sync`, and run `bin/test`. The `snails-core/` copy is replaced by the older release, so a failed upgrade is one pin edit away from a known state.

`SNALS_SOURCE="checkout"` follows the working tree rather than a release. To move a checkout project back to a published release, set `SNALS_SOURCE="pin"` and the release's `SNALS_REV` before syncing.

[Deploying](25-deploying.md) covers the image rebuild that follows a pin change; [Troubleshooting](27-troubleshooting.md) covers a sync that refuses the declaration.
