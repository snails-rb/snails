require_relative "test_helper"
require_relative "../snails-core/snails/harness"

# Gate mail capture (core) — the stamped config/environment.rb (carried
# by this fixture) registers DeliveryLog in test mode, so deliveries
# append one JSON line (to/from/subject, never the body) to the
# project's `tmp/mail-capture.jsonl` and nothing is transmitted. The
# reader side (assert_emails/emails, snails-core/snails/harness.rb) reads the same
# file from the harness target's cwd (`../tmp/...`); the gate engine
# empties it before boot. Registration semantics (explicit capture,
# providers, the unregistered raise) live in delivery_seam_test.
class DeliveryLogTest < Snails::Harness::IntegrationTest
  # The writer's path is spin-root relative ("tmp/..."), the reader's is
  # harness-dir relative ("../tmp/...") — the same file in a real gate
  # layout. This workspace has both cwds available, so each side is
  # pinned from its own anchor.
  LOG_PATH = "tmp/mail-capture.jsonl"
  READER_PATH = "../tmp/mail-capture.jsonl"

  def setup
    ENV.delete("APP_BASE_URL")
    File.delete(LOG_PATH) if File.exist?(LOG_PATH)
    File.delete(READER_PATH) if File.exist?(READER_PATH)
  end

  test "the stamped environment registers the capture in test mode" do
    assert_equal ActionMailer::DeliveryLog, ActionMailer::Base.delivery_method
  end

  test "the gate records deliveries into the project tmp log" do
    now_message = ActionMailer::Message.new({ to: "now@example.com", subject: "now", body: "b" })
    later_message = ActionMailer::Message.new({ to: "later@example.com", subject: "later", body: "b" })

    assert_equal now_message, now_message.deliver_now
    assert_equal later_message, later_message.deliver_later
    assert_equal 2, File.readlines(LOG_PATH).length
  end

  test "the recorded line carries to, from and subject" do
    message = ActionMailer::Message.new({
      to: [ "a@example.com", "b@example.com" ],
      from: "no-reply@example.org",
      subject: "code 1234",
      body: "your code is 1234"
    })
    message.deliver_now

    row = JSON.parse(File.readlines(LOG_PATH)[0])
    assert_equal [ "a@example.com", "b@example.com" ], row["to"]
    assert_equal "no-reply@example.org", row["from"]
    assert_equal "code 1234", row["subject"]
    assert_equal false, row.key?("body")
  end

  test "assert_emails and emails read the harness-relative log" do
    ENV["APP_BASE_URL"] = "http://127.0.0.1:1"
    Dir.mkdir("../tmp") unless Dir.exist?("../tmp")
    line = JSON.generate({ "to" => [ "one@example.com" ], "from" => nil, "subject" => "one" })
    assert_emails 1 do
      File.open(READER_PATH, "a") { |f| f.puts(line) }
    end
    assert_equal 1, emails.length
    assert_equal "one", emails[0]["subject"]
  end

  test "assert_emails skips without a live gate" do
    assert_emails 1 do
      assert_equal 1, 1
    end
  end
end
