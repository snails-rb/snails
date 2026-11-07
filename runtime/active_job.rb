# Entry index for the ActiveJob.
# The job stack: the class-side hand-off API and the queue adapter slot
# (`active_job/base`), the process-local default adapter
# (`active_job/process_queue`), the DB-backed adapter that shares the
# slot (`active_job/database_queue`), the drain loop (`active_job/worker`),
# the periodic registry and loop (`active_job/scheduler`), and the launcher
# that starts both loops (`active_job/launcher`). An app's own adapter takes
# the same slot.
#
# Load order: `base` defines the module, the drain flag, and the adapter slot;
# the children reopen `module ActiveJob` and read the slot only at call time, so
# this is the contract's reading order — module first, then the default adapter,
# then the DB adapter (its table models load with the `Snails` index later —
# call bodies resolve them, not the class body), then the loops that drive any
# adapter, then the launcher that starts them.
require_relative "active_job/base"
require_relative "active_job/process_queue"
require_relative "active_job/database_queue"
require_relative "active_job/worker"
require_relative "active_job/scheduler"
require_relative "active_job/launcher"
