# The app-tree directory that holds the vendored core.
#
# The core checkout keeps its own runtime/ name: the dist's five paths are a
# release contract, so only the destination name changes. Sourced by the CLI
# and its engines — do not repeat the literal elsewhere.
# shellcheck shell=bash
SNAILS_VENDOR_DIR="snails-core"
export SNAILS_VENDOR_DIR
