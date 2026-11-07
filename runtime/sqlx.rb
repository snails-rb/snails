# The raw-SQL standard — not an ORM: no callbacks, no validations, no
# relation or condition builders. The caller writes the SQL; the model
# maps rows. This module owns the whole surface: the base apps subclass,
# the query and row layers, the error interface, and the adapter helpers
# (literals, dialect name, transaction).
#
# Load order: everything `Base` extends or includes must be defined first;
# `adapter.rb` reopens `Base` with `.transaction`, so it loads last.
require_relative "sqlx/query"
require_relative "sqlx/model"
require_relative "sqlx/row"
require_relative "sqlx/enum"
require_relative "sqlx/json"
require_relative "sqlx/errors"
require_relative "sqlx/base"
require_relative "sqlx/adapter"
