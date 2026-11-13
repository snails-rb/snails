# The pre-build generator step: the single sequence every build runs before
# `spin build`.
#
# spinel is AOT: it analyses the require graph statically, so the folder-wide
# require list, the route path helpers, and the model column map must be
# regenerated from the tree as it stands before each compile. A build that
# skips this step compiles stale output from the previous run: a new
# controller missing from gen/controllers.rb fails at runtime with a
# NameError instead of failing the build.
#
# This used to live in each app's bin/test and bin/dev wrappers, so
# `snails harness test` — the engine those wrappers call and CI invokes
# directly — built a stale tree when run on its own. It now lives here, next
# to the build it gates.
#
# Sourced (never executed) — defines run_generators.
# shellcheck shell=bash

# run_generators <cli> <app_root> — refresh gen/* from the app's sources.
# The order follows the boot chain: the require-all lists come first because
# they determine which files the other two generators parse. Writes happen
# only when content changes, so an unchanged tree costs nothing and source
# mtimes (which the harness bundle cache uses) stay the same. A generator's
# non-zero exit stops the caller; the build must not run against a
# half-regenerated tree.
run_generators() { # <cli> <app_root>
  local cli="$1" app_root="$2"
  "$cli" gen-require-all "$app_root"
  "$cli" gen-route-helpers "$app_root"
  "$cli" gen-model-columns "$app_root"
}
