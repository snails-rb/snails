# Loads every form under app/forms/ — Snails::Form subclasses.
#
# Runs after the model group: a rule option may name a model constant at load
# time (`uniqueness: { model: User }`). The scan recurses so a form under a
# namespace folder loads too.
# >>> snails generate
# scan: forms/**/*
# <<< snails generate
