# Loads app/controllers/concerns/ and then every controller under app/controllers/.
#
# The only controller load edge — config/routes.rb declares the route table and
# nothing else. Scan order is load order; `controllers/**/*` recurses.
# >>> snails generate
# scan: controllers/concerns/**
# scan: controllers/**/*
# <<< snails generate
