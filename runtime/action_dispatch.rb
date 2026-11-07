# Entry index for the request layer: the route matcher, the exception classes
# `rescue_from` clauses name, the header view, the typed request, and the two
# body readers (multipart form data and nested params).
#
# The files do not reopen one another, so this order is only the reading order.
require_relative "action_dispatch/router"
require_relative "action_dispatch/exceptions"
require_relative "action_dispatch/headers"
require_relative "action_dispatch/request"
require_relative "action_dispatch/multipart"
require_relative "action_dispatch/param_builder"
