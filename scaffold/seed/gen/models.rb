# Loads every model under app/models/ — table-oriented Sqlx::Base classes.
# Recursive: a model may live under a namespace folder (e.g. snails/queue_job.rb).
# >>> snails generate
# scan: models/**/*
# <<< snails generate
