# Snails ext — runtime extensions to builtin classes (Integer, String, Time, ...).
#
# Extensions add only new methods. Never override a builtin one: `super` cannot
# reach the builtin implementation (NoMethodError), so an override loses the
# original behavior.
require_relative "ext/integer"
require_relative "ext/string"
require_relative "ext/enumerable"
require_relative "ext/array"
require_relative "ext/hash"
require_relative "ext/object"
require_relative "ext/time"
