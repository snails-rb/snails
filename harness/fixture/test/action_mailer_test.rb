require_relative "test_helper"
require_relative "harness_runner"

class MailerDefaultsBase < ActionMailer::Base
end

class MailerDefaultsApplication < MailerDefaultsBase
  default from: "app@example.com", replyto: "reply@example.com", subject: "hello"
end

class MailerDefaultsUser < MailerDefaultsApplication
  default from: "user@example.com"
end

class MailerDefaultsOther < MailerDefaultsApplication
end

# ActionMailer defaults, strict inputs, and the deliver_later queue path.
class ActionMailerTest < TestBase
  def setup
    Snails.env = "test"
    ActiveJob::EXECUTORS.clear
    ActiveJob.queue_adapter = ActiveJob::ProcessQueue
    ActiveJob::ProcessQueue::PENDING.clear
    ActionMailer::Base.deliveries.clear
    ActionMailer::Base.delivery_method = ActionMailer::CaptureMethod
  end

  def assert_equal(expected, actual, msg = nil)
    raise(msg || "expected #{expected.inspect}, got #{actual.inspect}") unless expected == actual
  end

  def new_message
    ActionMailer::Message.new({ to: "user@example.com", subject: "s", body: "b" })
  end

  # The application defaults flow to every subclass, a subclass overrides
  # one key for itself, and the call options win over both.
  def test_default_inherits_and_overrides
    user = MailerDefaultsUser.new
    message = user.mail(to: "user@example.com")
    assert_equal "user@example.com", message.from
    assert_equal "reply@example.com", message.replyto
    assert_equal "hello", message.subject

    other = MailerDefaultsOther.new.mail(to: "other@example.com")
    assert_equal "app@example.com", other.from

    overridden = user.mail(to: "user@example.com", from: "call@example.com")
    assert_equal "call@example.com", overridden.from

    assert_equal nil, MailerDefaultsBase.new.mail(to: "base@example.com").from
  end

  # The reader exposes the effective hash, not just the class's own
  # declarations.
  def test_defaults_reads_the_merged_hash
    assert_equal(
      { from: "user@example.com", replyto: "reply@example.com", subject: "hello" },
      MailerDefaultsUser.defaults
    )
    assert_equal({}, MailerDefaultsBase.defaults)
  end

  # A non-Hash or a block is a declaration mistake, not a silent no-op.
  def test_default_rejects_unsupported_forms
    nil_error = rescue_error { MailerDefaultsBase.default(nil) }
    assert_equal true, nil_error.is_a?(ArgumentError)
    assert_equal true, nil_error.message.include?("Hash")

    block_error = rescue_error { MailerDefaultsBase.default { "x" } }
    assert_equal true, block_error.is_a?(ArgumentError)
    assert_equal true, block_error.message.include?("block")
  end

  # `mail` itself rejects a non-Hash before the message is built.
  def test_mail_rejects_a_non_hash
    error = rescue_error { MailerDefaultsUser.new.mail(nil) }
    assert_equal true, error.is_a?(ArgumentError)
    assert_equal true, error.message.include?("Hash")
  end

  # Test mode delivers inline: the gate's capture sees the message in the
  # same call, before any worker loop runs.
  def test_deliver_later_in_test_mode_delivers_inline
    before = ActionMailer::Base.deliveries.length
    message = new_message
    result = message.deliver_later

    assert_equal before + 1, ActionMailer::Base.deliveries.length
    assert_equal message, result
  end

  # With an executor, deliver_later returns without running the provider on
  # the caller's thread; the queue drain delivers the rebuilt message.
  def test_deliver_later_queues_when_an_executor_is_registered
    Snails.env = "development"
    ActiveJob.register_executor
    before = ActionMailer::Base.deliveries.length
    message = new_message

    result = message.deliver_later
    assert_equal message, result
    assert_equal before, ActionMailer::Base.deliveries.length
    assert_equal 1, ActiveJob::ProcessQueue.pending_count

    assert_equal 1, ActiveJob::ProcessQueue.drain
    assert_equal before + 1, ActionMailer::Base.deliveries.length
    delivered = ActionMailer::Base.deliveries[before]
    assert_equal "user@example.com", delivered.to
    assert_equal "s", delivered.subject
    assert_equal "b", delivered.body
  end

  # Without an executor the ActiveJob rule applies: the job runs at the
  # call site, so the mail is not silently stranded in a queue nobody drains.
  def test_deliver_later_without_an_executor_delivers_at_the_call_site
    Snails.env = "development"
    before = ActionMailer::Base.deliveries.length
    message = new_message

    result = message.deliver_later
    assert_equal message, result
    assert_equal before + 1, ActionMailer::Base.deliveries.length
  end

  def rescue_error
    yield
    nil
  rescue StandardError => error
    error
  end
end

FixtureRunner.run(ActionMailerTest, [
  "test_default_inherits_and_overrides",
  "test_defaults_reads_the_merged_hash",
  "test_default_rejects_unsupported_forms",
  "test_mail_rejects_a_non_hash",
  "test_deliver_later_in_test_mode_delivers_inline",
  "test_deliver_later_queues_when_an_executor_is_registered",
  "test_deliver_later_without_an_executor_delivers_at_the_call_site"
])
