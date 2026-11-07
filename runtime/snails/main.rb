# `Snails::Main` — the app entry contract shared by every snails app.
#
# The entry index loads the request path (`main/dispatch.rb`) and the process
# entry (`main/server.rb`). Boot requires this file before the app's
# `config/environment.rb`, so an app reopen wins over these defaults (the last
# loaded definition wins).
require_relative "main/dispatch"
require_relative "main/server"
