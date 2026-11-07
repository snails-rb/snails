# Fixture boot — the small harness has no app tree, so its test entry points
# at the core boot chain directly. A consumer app's harness target reaches
# the same file through `../snails-core/boot`.
require_relative "snails-core/boot"
