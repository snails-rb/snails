# Email

A Snails app builds the message; your app owns the way it leaves the process. There are no templates and no built-in SMTP client — you write the subject and body in code and register a delivery class that talks to your provider.

## Create a mailer

Put mailer classes in `app/mailers/`. A small app needs one base class and one mailer:

```ruby
# app/mailers/application_mailer.rb
class ApplicationMailer < ActionMailer::Base
  default from: "hello@example.com"
end
```

```ruby
# app/mailers/welcome_mailer.rb
class WelcomeMailer < ApplicationMailer
  def welcome(email)
    mail(
      to: email,
      subject: "Welcome",
      body: "Thanks for joining us."
    )
  end

  def self.welcome(email)
    new.welcome(email)
  end
end
```

`default` sets header values for every message built by that class and its subclasses. A value passed to `mail` wins over the default; a subclass can add its own default. Only `to`, `from`, `replyto`, `subject`, and `body` are modeled. `body` is the message text — there is no template lookup.

Mailers under `app/mailers/` load through `gen/mailers.rb`; drop the file there (subfolders included) and the next `bin/dev` or `bin/test` adds it to the list.

## Register a delivery class

The app sends through a class you register in `config/environment.rb`. The class answers `deliver(message)` and returns the message:

```ruby
# app/lib/my_mail_delivery.rb
class MyMailDelivery
  def self.deliver(message)
    # Send message.to, message.from, message.subject, and message.body
    # through your provider's HTTP API.
    message
  end
end
```

```ruby
# config/environment.rb
ActionMailer::Base.delivery_method = MyMailDelivery
```

The class is read at delivery time, so you can swap it per environment. A fresh app registers `ActionMailer::DeliveryLog` in test mode; keep that line last so tests keep the capture. With no class registered in development or production, the first delivery raises instead of silently going nowhere.

## Send now or later

```ruby
WelcomeMailer.welcome("sue@example.com").deliver_now
WelcomeMailer.welcome("sue@example.com").deliver_later
```

`deliver_now` calls the delivery class on the spot and returns the message. `deliver_later` hands the message to the job queue and returns without waiting for the provider. In test mode it runs inline so the capture sees it immediately; in a process with no worker loop it also runs inline rather than stranding the message.

A failure from a later delivery is recorded by the job system rather than raised in the caller. If you need to handle a provider failure directly, use `deliver_now`.

## Test it

In test mode, a fresh app records each delivery to `tmp/mail-capture.jsonl` — recipient, sender, and subject; not the body, which may carry a reset token. A harness case can count and read deliveries from the running server:

```ruby
assert_emails 1 do
  post("/signup", params: { email: "sue@example.com" }, as: :json)
end
assert_equal "Welcome", emails.last["subject"]
```

`assert_emails` counts the lines the block added; `emails` returns the run's rows in send order, each with `"to"` (an Array), `"from"`, and `"subject"`. The gate empties the file before boot, so a case never sees another run's mail.

For a direct test of the mailer, register `ActionMailer::CaptureMethod` and read `ActionMailer::Base.deliveries` in the same process:

```ruby
ActionMailer::Base.delivery_method = ActionMailer::CaptureMethod
WelcomeMailer.welcome("sue@example.com").deliver_later
assert_equal 1, ActionMailer::Base.deliveries.length
```

The server is a separate process, so `deliveries` there is not visible to the harness. The file is the shared observation point for a live server; `CaptureMethod` is for a case that calls a mailer directly.

## What is not included

There are no templates, attachments, CC/BCC headers, or SMTP client. A message carries `to`, `from`, `replyto`, `subject`, and `body`. Durability and retry behavior depend on the job queue adapter and your provider; the mailer itself does not retry.

That is the whole path: build the message in a mailer, register a delivery class, and call `deliver_now` or `deliver_later`. [Background Jobs](15-background-jobs.md) covers what `deliver_later` hands the queue to.
