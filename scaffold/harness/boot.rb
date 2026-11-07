# Harness target boot — the core boot chain plus the core harness library.
#
# The app target (main.rb) starts the server; this target loads the app graph
# and the library only, so a case can drive the running server over real HTTP.
# The harness holds no core or app of its own — both are core-owned.
require_relative "../snails-core/boot"
require_relative "../snails-core/snails/harness"
