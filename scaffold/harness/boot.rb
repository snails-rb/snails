# Harness target boot — the core boot chain plus the core harness library.
#
# The app target (main.rb) starts the server; this target loads the app graph
# and the library only, so a case can drive the running server over real HTTP.
# The harness directory holds no core or app code of its own; it loads both
# from their owning trees.
require_relative "../snails-core/boot"
require_relative "../snails-core/snails/harness"
