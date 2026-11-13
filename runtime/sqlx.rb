# The raw-SQL layer — not an ORM: no callbacks, validations, relations, or
# condition builders. The caller writes the SQL; the model maps rows.
#
# Load order: everything `Base` extends or includes loads first, and
# `adapter.rb` reopens `Base` with `.transaction`, so it loads last.
require_relative "sqlx/query"
require_relative "sqlx/model"
require_relative "sqlx/row"
require_relative "sqlx/enum"
require_relative "sqlx/json"
require_relative "sqlx/errors"
require_relative "sqlx/base"
require_relative "sqlx/adapter"
