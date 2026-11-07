module ActionMailer
  # The queue half of deliver_later: rebuilds the message and delivers it.
  class DeliveryJob < ActiveJob::Base
    # `perform(data)` — rebuild the message from the serialized payload and
    # deliver it. The provider's failure reaches the job boundary, which
    # records it as `job.failed`.
    #
    # @param data [Hash{String => untyped}] the delivery payload
    # @return [void]
    # @raise [RuntimeError] no delivery method is registered
    def self.perform(data)
      message = Message.new({
        to: data["to"],
        from: data["from"],
        replyto: data["replyto"],
        subject: data["subject"],
        body: data["body"]
      })
      ActionMailer::Base.delivery_method.deliver(message)
    end
  end
end
