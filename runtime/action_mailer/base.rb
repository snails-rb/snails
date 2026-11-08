module ActionMailer
  # The mailer class: header defaults, the delivery seam, and captured mail.
  class Base
    # store header defaults on this class. `mail` puts them under its call
    # options, and subclasses inherit them through `defaults`.
    #
    # @param opts [Hash{Symbol => Object}] the mailer defaults
    # @return [void]
    # @raise [ArgumentError] opts is not a Hash, or a block was given
    def self.default(opts = nil)
      if block_given?
        raise ArgumentError, "default does not support a block — pass the options as a Hash"
      end
      # Negated if: spinel drops a raise from an unless is_a? guard with a nilable sidecar.
      if !opts.is_a?(Hash)
        raise ArgumentError, "default expects a Hash of header options"
      end

      @defaults ||= {}
      opts.each { |key, value| @defaults[key] = value }
    end

    # the effective defaults for this class: the parent chain's values with this
    # class's declarations on top.
    #
    # @return [Hash{Symbol => Object}] the merged header defaults
    def self.defaults
      parent = superclass
      inherited = parent.respond_to?(:defaults) ? parent.defaults : {}
      inherited.merge(@defaults || {})
    end

    # the in-memory list `CaptureMethod` pushes into.
    #
    # @return [Array[Message]] the captured messages
    def self.deliveries
      @deliveries ||= []
    end

    # the registered class answering `deliver(message) -> message`.
    #
    # @return [_DeliveryMethod] the registered method
    # @raise [RuntimeError] no method was registered
    def self.delivery_method
      return @delivery_method if @delivery_method

      raise "no delivery method registered — set ActionMailer::Base.delivery_method in config/environment.rb (or ActionMailer::CaptureMethod to collect without sending)"
    end

    # A nil assignment unregisters; the next delivery raises.
    def self.delivery_method=(method)
      @delivery_method = method
    end

    # build a message with the class defaults under the call options, so a
    # per-call value wins.
    #
    # @param opts [Hash{Symbol => Object}] the call's header options
    # @return [Message] the built message
    # @raise [ArgumentError] opts is not a Hash
    def mail(opts)
      # Same negated guard as `default`.
      if !opts.is_a?(Hash)
        raise ArgumentError, "mail expects a Hash of header options"
      end

      Message.new(self.class.defaults.merge(opts))
    end
  end
end
