# App settings — read through `Snails.app.<name>`.
#
# Values only: environment-dependent wiring (time zone, queue adapter, mailer,
# boot settings) lives in config/environment.rb. Project template: `snails new`
# fills in app_name; app-owned afterwards.
module Snails
  class Application
    def app_name
      "__APP_NAME__"
    end
  end
end
