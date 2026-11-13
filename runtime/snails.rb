# Entry index for the `Snails` global, the app-facing façade. One concept
# per file under snails/; this file owns only the load order.
#
# Deliberately metaprogramming-free: every method is explicit, so the
# spinel AOT compile and the runtime typing bar both hold.
#
# Load order: `utils` is a constant-only vocabulary table with no
# dependencies; `root_path` and `env` are plain value objects; `logger` must
# load before the files that reopen it (`logger/formatter`,
# `logger/record`, `logger/record_formatter`, `logger/delivery`,
# `logger/context`, `logger/log_delivery_job`, `logger/otlp_transport`);
# `version` is constant-only metadata and loads before
# `application`, which must precede the app's config/application.rb reopen.
# The zone vocabulary (`Snails.iana_zone`) and process slot
# (`Snails.time_zone`) live in snails/time_zone.rb, which boot requires next.
require_relative "snails/utils"
require_relative "snails/root_path"
require_relative "snails/error_boundary"
require_relative "snails/env"
require_relative "snails/cache"
require_relative "snails/logger"
require_relative "snails/logger/formatter"
require_relative "snails/logger/record"
require_relative "snails/logger/record_formatter"
require_relative "snails/logger/delivery"
require_relative "snails/logger/context"
require_relative "snails/logger/log_delivery_job"
require_relative "snails/logger/otlp_transport"
require_relative "snails/version"
require_relative "snails/application"

require_relative "snails/form/rule_options"
require_relative "snails/form/rule_engine"
require_relative "snails/form/errors"
require_relative "snails/form"

# The queue layer, the routing surface, and the process entry load last:
# they open `Sqlx::Base`, `ActiveJob::Base`, and `ActionController::API`,
# which boot loads before this file.
require_relative "snails/queue/job"
require_relative "snails/queue/occurrence"
require_relative "snails/queue/prune_job"
require_relative "snails/health_controller"
require_relative "snails/route_dsl"
require_relative "snails/main"
