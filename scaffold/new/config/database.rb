# The app's DB adapter choice — boot requires this file as ../config/database, so it must
# require exactly one backend.
#
# Both backends define `Sqlx::Database`; spinel's static graph keeps only the
# required one. App-owned: switch adapters by changing the require below.
require_relative "../snails-core/database/__DB_BACKEND__"
