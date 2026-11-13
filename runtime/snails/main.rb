# The app entry contract shared by every snails app.
#
# Loads the request path and the process entry; boot requires this before the
# app's `config/environment.rb`, so an app's reopen wins over these defaults.
require_relative "main/dispatch"
require_relative "main/server"
