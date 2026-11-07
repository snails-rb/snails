# Snails ext — the runtime's ergonomic method extensions over the builtins.
#
# One file per builtin class, each adding NEW methods only. Overriding a
# builtin method is off the table: `super` cannot reach the builtin
# implementation (a runtime NoMethodError), so an override would lose the
# original behavior. A reopen also carries class-level side effects the
# method list cannot show — Time-typed slots enforce program-wide, so no
# method needs an in-body guard (ext/time.rb carries the detail).
require_relative "ext/integer"
require_relative "ext/string"
require_relative "ext/enumerable"
require_relative "ext/array"
require_relative "ext/hash"
require_relative "ext/object"
require_relative "ext/time"
