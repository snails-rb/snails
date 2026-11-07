# Loads every model under app/models/ — table-oriented Sqlx::Base classes.
# >>> snails generate
# scan: models/**/*
require_relative "../app/models/comment"
require_relative "../app/models/post"
# <<< snails generate
