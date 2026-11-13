# Entry index for the ActiveJob slice: the class-side hand-off API, the adapter
# slot, the default and DB-backed adapters, the worker, scheduler, and launcher.
#
# Load order is a contract: `base` defines the module and the adapter slot; the
# background loops load before the launcher, and DB models resolve at call time.
require_relative "active_job/base"
require_relative "active_job/process_queue"
require_relative "active_job/database_queue"
require_relative "active_job/worker"
require_relative "active_job/scheduler"
require_relative "active_job/launcher"
