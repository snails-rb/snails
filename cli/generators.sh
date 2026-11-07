# The pre-build generator step — one source for the sequence every build
# runs before `spin build`.
#
# spinel is AOT: it analyses the require graph statically, so the folder-wide
# require list, the route path helpers, and the model column map have to be
# regenerated from the tree as it stands before a compile. A build that skips
# this compiles whatever the last run left behind — a new controller missing
# from gen/controllers.rb loads as a runtime NameError, not a build failure.
#
# This used to live in each app's bin/test and bin/dev wrapper, which made
# `snails harness test` (the engine those wrappers call, and what CI calls
# directly) build a stale tree when invoked on its own. It lives here now, next
# to the build it gates.
#
# Sourced (never executed) — defines run_generators.
# shellcheck shell=bash

# run_generators <cli> <app_root> — refresh gen/* from the app's sources.
# Order is the boot chain's: the require-all lists come first because they
# decide which files the other two parse. Content-gated writes, so an
# unchanged tree costs nothing and source mtimes (the harness bundle cache
# keys on them) stay put. A generator's non-zero exit stops the caller — the
# build must not run against a half-regenerated tree.
run_generators() { # <cli> <app_root>
  local cli="$1" app_root="$2"
  "$cli" gen-require-all "$app_root"
  "$cli" gen-route-helpers "$app_root"
  "$cli" gen-model-columns "$app_root"
}
