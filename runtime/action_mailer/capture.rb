module ActionMailer
  # Collect deliveries in memory instead of transmitting them.
  module CaptureMethod
    def self.deliver(message)
      ActionMailer::Base.deliveries.push(message)
      message
    end
  end

  # The test gate's capture: append one JSON line per delivery to
  # `tmp/mail-capture.jsonl` without the body, which can carry reset tokens.
  module DeliveryLog
    # Spin-root relative; the harness reads the same file as `../tmp/...`.
    PATH = "tmp/mail-capture.jsonl"

    # `deliver(message)` — append one JSON line and return the message.
    #
    # @param message [Message] the built mail
    # @return [Message] the same message
    # @example one recorded line
    #   {"to":["user@example.com"],"from":null,"subject":"Welcome"}
    def self.deliver(message)
      Dir.mkdir("tmp") unless Dir.exist?("tmp")
      recipients = message.to
      line = {
        "to" => recipients.is_a?(Array) ? recipients : [ recipients ],
        "from" => message.from,
        "subject" => message.subject.to_s
      }
      File.open(PATH, "a") { |f| f.puts(JSON.generate(line)) }
      message
    end
  end
end
