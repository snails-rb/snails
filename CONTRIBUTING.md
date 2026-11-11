# Contributing to Snails

Thanks for taking the time to improve Snails. Bug reports, focused pull requests, and manual fixes are all welcome.

## Before you open an issue

- Search existing issues first.
- For a bug, use the bug report template and include `snails --version`, the OS, the command you ran, the output, and a minimal reproduction.
- For a feature, open an issue before writing the implementation. Snails is alpha, and scope is discussed before code.
- Redact tokens, keys, passwords, and private data from logs and pasted output.

## Development checks

The public repository checks are shell scripts under `scripts/`:

```sh
bash scripts/test-runtime.sh
bash scripts/test-cli.sh
bash scripts/test-migrate.sh
```

The scripts materialize the pinned spinel toolchain themselves; a global `spinel` install is not required. The CI workflow in `.github/workflows/ci.yml` is the authoritative gate. Platform and PostgreSQL coverage runs in `platform-ci.yml` after merge.

For a manual-only change, keep the examples and links valid and run any command a chapter tells the reader to run. Do not invent output.

## Pull requests

- Work on a short-lived branch and open a pull request against `main`. Do not push directly to `main`.
- Keep one change focused. A bug fix and an unrelated refactor belong in separate PRs.
- Write a title that names the change, in sentence case, with no `type:` prefix: `Drop the remote plan`, not `feat: drop the remote plan`.
- In the body, say what changed, why, and how you verified it. If the change is docs-only, say so.
- Manual chapters live in `manual/`; the published site is a synced copy. Edit the source chapter, not the site copy.

## Code and docs

- Code, tests, scripts, comments, and CLI output are English.
- Follow the existing structure and naming. A new abstraction needs a reason, not just a preference.
- Do not add a runtime dependency for a small convenience. Snails compiles app and framework into one binary.
- Keep public behavior documented in `manual/` when it changes.

## License

By contributing, you agree that your contribution is licensed under the MIT License in [`LICENSE`](LICENSE).
