# Harness fixture for the app's environment file — the way an app
# carries its config/environment.rb. It loads as boot's LAST require
# (after the core defaults in snails-core/snails/main.rb) and must win; the
# override test asserts that.

# The stamped boot-settings line (scaffold/new/config/environment.rb),
# carried as a real app would — `tz_mapping_test` asserts it ran.
Snails.time_zone = "UTC"

# The logger slots the contract tests read back — the app-owned settings
# an environment file configures after the core defaults load.
Snails.logger.level = :info
Snails.logger.progname = "fixture"

# The stamped mail registration — test mode captures the gate's
# deliveries (delivery_log_test asserts the registration ran).
ActionMailer::Base.delivery_method = ActionMailer::DeliveryLog if Snails.env.test?

module Snails
  module Main
    # Marker return: proves this definition ran instead of the core one
    # (the core `configure_database!` delegates to Sqlx::Database and would touch the
    # app's storage file from a test binary).
    def self.configure_database!
      "app:configure_database!"
    end
  end
end
