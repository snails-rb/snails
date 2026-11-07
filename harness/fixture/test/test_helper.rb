# Harness test helper — loads the boot chain only (no DB configure:
# harness cases drive instances and never touch server or DB).
require_relative "../boot"

# Captures the logger's failure reports so a snapshot stays stable — the
# default line carries a clock and a pid. Messages only: the line shape is
# logger_test's contract.
class CapturedLog
  def initialize
    @messages = []
  end

  def messages
    @messages
  end

  def write(message)
    @messages << message
  end

  def flush
  end
end

class MessageOnlyFormatter
  def call(severity, time, progname, message)
    message.to_s
  end
end

# Captures delivered records flat, so a case can assert an event and its
# fields without the local line's clock and pid.
class RecordCapture
  def initialize
    @records = []
  end

  def records
    @records
  end

  def deliver(records)
    records.each { |record| @records << record }
  end
end

class TestBase
  def setup
  end
end
