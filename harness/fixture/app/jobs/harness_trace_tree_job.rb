# The job in the tracing tree: it records a run and reads once through the DB
# adapter, so the consumer span has a DB child of its own.
module HarnessTraceTreeSink
  RAN = []
end

class HarnessTraceTreeJob < ActiveJob::Base
  def self.perform(data)
    HarnessTraceTreeSink::RAN << (data.nil? ? 0 : data["n"])
    Sqlx::Database.exec_read("SELECT 1 AS one", [])
  end
end
