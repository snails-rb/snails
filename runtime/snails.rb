# Entry index for the `Snails` global, the app-facing façade. This file owns the
# load order of the one-concept-per-file modules under snails/.
#
# `logger` loads before the files that reopen it, and `application` loads before
# the app's config/application.rb reopen.
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
