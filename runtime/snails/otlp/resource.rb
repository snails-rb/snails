# frozen_string_literal: true

# The process-wide resource attributes both OTLP signals send once per batch.
# The signal owner adds its schema version; this module owns the values every
# signal shares.
module Snails
  module OTLP
    module Resource
      # The resource attributes for the running process. `service.version` is
      # omitted when the app declares none; an empty host name is omitted too.
      #
      # @return [Hash{String => Object}] the shared resource attributes
      def self.attributes
        fields = {}
        fields["service.name"] = Snails.app.app_name
        version = Snails.app.version
        fields["service.version"] = version unless version.nil?
        host = Snails.logger.host_name
        fields["host.name"] = host unless host.nil? || host.empty?
        fields["process.pid"] = Process.pid
        fields["deployment.environment.name"] = Snails.env.name
        fields["snails.version"] = Snails.version
        fields["snails.rev"] = Snails.rev
        fields
      end
    end
  end
end
