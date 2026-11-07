# App settings — read through `Snails.app.<name>`.
#
# Values only: environment-dependent wiring (time zone, queue adapter, mailer,
# boot parks) lives in config/environment.rb. Seeded once; app-owned afterwards.
module Snails
  class Application
    def app_name
      "app"
    end
  end
end
