module ActionMailer
  # One built mail: the header values and the delivery entry points.
  class Message
    def initialize(opts)
      @to = opts[:to]
      @from = opts[:from]
      @replyto = opts[:replyto]
      @subject = opts[:subject]
      @body = opts[:body]
    end

    def to
      @to
    end

    def from
      @from
    end

    def replyto
      @replyto
    end

    def subject
      @subject
    end

    def body
      @body
    end

    # `deliver_now()` — deliver through the registered method and return the
    # message.
    #
    # The seam name is `deliver`: every same-name method in the program must
    # fit this signature.
    #
    # @return [Message] the delivered message
    def deliver_now
      ActionMailer::Base.delivery_method.deliver(self)
    end

    # `deliver_later()` — queue the delivery outside test mode and return the
    # message. Test mode stays inline so `DeliveryLog` / `assert_emails` see
    # the line immediately; with no executor, ActiveJob runs it at the call
    # site.
    #
    # @return [Message] this message
    def deliver_later
      if Snails.env.test?
        deliver_now
      else
        ActiveJob.enqueue(ActionMailer::DeliveryJob, delivery_payload)
        self
      end
    end

    # The string-keyed payload a store-backed queue carries.
    def delivery_payload
      {
        "to" => @to,
        "from" => @from,
        "replyto" => @replyto,
        "subject" => @subject,
        "body" => @body
      }
    end

    private :delivery_payload
  end
end
