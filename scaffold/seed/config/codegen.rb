# The app's load edges — the one require list into app/.
#
# app/ has no autoload and spinel's AOT graph follows literal requires only,
# so every app file is reached through a gen/* load list listed here. App
# files carry no require_relative of their own; the exception is a load-time
# constant that names another file's constant — that file requires its source.
#
# Seeded once; app-owned afterwards.
require_relative "../gen/lib"
require_relative "../gen/controllers"
require_relative "../gen/helpers"
require_relative "../gen/mailers"
require_relative "../gen/models"
require_relative "../gen/model_columns"
require_relative "../gen/forms"
require_relative "../gen/jobs"
require_relative "../gen/services"
require_relative "../gen/route_helpers"
