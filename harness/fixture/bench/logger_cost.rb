# Logger cost bench — measurements only, no assertions. It splits one
# production-shaped logger call into its parts so an optimization can be
# ranked by measured share instead of by how visible the code looks.
#
# Every case runs on one thread and on several at once. A part that is cheap
# alone but serialized across threads shows up in the multi-thread columns,
# which is the shape the request path has: one thread per request.
#
# Two outputs answer different questions:
#
#   null     discards the line in memory — the logger's own work
#   devnull  writes it to /dev/null — adds the descriptor write syscall
#
# Driven by scripts/bench-logger.sh; the environment variables it sets are
# the only input.
#
# Exit: 0 when every case ran, 1 otherwise.
require_relative "../boot"

# The record builders are private on purpose — the logger is their only
# caller. Measuring them needs a public door, and adding one here keeps the
# production surface unchanged: this reopen exists only in the bench binary.
module Snails
  class Logger
    # the request/job correlation bag the logger merges into every record.
    def bench_context_fields
      context_fields
    end

    # the service/process bag every record carries for the transport.
    def bench_resource_fields
      resource_fields
    end
  end
end

# Discards the line without touching a descriptor.
class NullLineOutput
  def write(line)
  end

  def flush
  end
end

# Writes to /dev/null: the descriptor write a real log stream pays, without a
# disk behind it. sync is on, so each line reaches the descriptor the way the
# production output does.
class DevNullLineOutput
  def initialize
    @file = File.open("/dev/null", "w")
  end

  def sync=(on)
    @file.sync = on
  end

  def write(line)
    @file.write(line)
  end
end

def read_list(name, fallback)
  raw = ENV[name]
  raw = fallback if raw.nil? || raw.empty?
  parts = raw.split(",")
  values = []
  i = 0
  while i < parts.length
    values << parts[i].to_i
    i += 1
  end
  values
end

THREAD_COUNTS = read_list("BENCH_THREADS", "1,8")
ROUNDS = read_list("BENCH_ROUNDS", "5")[0]
ITERATIONS = read_list("BENCH_ITERATIONS", "20000")[0]
OUTPUT = ENV["BENCH_OUTPUT"] || "null"

if OUTPUT == "devnull"
  Snails.logger.output = DevNullLineOutput.new
else
  Snails.logger.output = NullLineOutput.new
end
Snails.logger.level = :info

# The same call shape `Tep::App` makes for one request.
MESSAGE = "GET /up 200"
FIELDS = {
  "http.request.method" => "GET",
  "url.path" => "/up",
  "http.response.status_code" => 200,
  "snails.duration_ms" => 0.213,
  "snails.db_ms" => 0.0
}

CONTEXT = Snails.logger.bench_context_fields
RESOURCE = Snails.logger.bench_resource_fields
RECORD = Snails::Logger::Record.new(:info, "request.completed", MESSAGE,
                                    fields: FIELDS, context: CONTEXT, resource: RESOURCE)
RECORD_FORMATTER = Snails.logger.record_formatter
LINE_FORMATTER = Snails.logger.formatter
LINE = RECORD_FORMATTER.call(RECORD, Snails.logger.progname)
WRITE_LOCK = Mutex.new
SEVERITIES = [ "I", "INFO" ]

CASE_FULL_EVENT = 1
CASE_FULL_MESSAGE = 2
CASE_RECORD_EMPTY = 3
CASE_RECORD_FIELDS = 4
CASE_RECORD_FULL = 5
CASE_RESOURCE_FIELDS = 6
CASE_CONTEXT_FIELDS = 7
CASE_RESERVED_SCAN = 8
CASE_NAME_PATTERN = 9
CASE_RENDER = 10
CASE_FORMAT_TIME = 11
CASE_LINE = 12
CASE_PID_TEXT = 13
CASE_LOCK = 14
CASE_WRITE = 15
CASE_TIME_UTC = 16
CASE_BEGIN_REQUEST = 17
CASE_LEVEL_GATE = 18
CASE_FLOAT_TEXT = 19

CASE_LABELS = {
  1 => "request path: info(event:, fields:)",
  2 => "message path: info(message)",
  3 => "  Record.new (no fields, no bags)",
  4 => "  Record.new (5 fields)",
  5 => "  Record.new (5 fields + both bags)",
  6 => "  resource_fields",
  7 => "  context_fields",
  8 => "  RESERVED_FIELDS.include? x5",
  9 => "  FIELD_PATTERN.match? x5",
  10 => "  record_formatter.call",
  11 => "  Formatter.format_time(Time.now)",
  12 => "  Formatter#call (default line)",
  13 => "  Process.pid.to_s",
  14 => "  Mutex#synchronize (empty)",
  15 => "  io.write(line) + flush",
  16 => "  Time.now.utc",
  17 => "  Context.begin_request",
  18 => "  info? level gate",
  19 => "  Float#to_s x2"
}

def clock_ns
  (Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000000000.0).to_i
end

# One thread's share of a case. Answers a checksum so the compiler cannot
# prove the work unused; the value is printed once per run.
def run_iterations(case_id, count)
  checksum = 0
  i = 0
  while i < count
    if case_id == CASE_FULL_EVENT
      Snails.logger.info(MESSAGE, event: "request.completed", fields: FIELDS)
    elsif case_id == CASE_FULL_MESSAGE
      Snails.logger.info(MESSAGE)
    elsif case_id == CASE_RECORD_EMPTY
      built = Snails::Logger::Record.new(:info, "request.completed", MESSAGE)
      checksum = checksum + built.fields.length
    elsif case_id == CASE_RECORD_FIELDS
      built = Snails::Logger::Record.new(:info, "request.completed", MESSAGE, fields: FIELDS)
      checksum = checksum + built.fields.length
    elsif case_id == CASE_RECORD_FULL
      built = Snails::Logger::Record.new(:info, "request.completed", MESSAGE,
                                         fields: FIELDS, context: CONTEXT, resource: RESOURCE)
      checksum = checksum + built.fields.length
    elsif case_id == CASE_RESOURCE_FIELDS
      checksum = checksum + Snails.logger.bench_resource_fields.length
    elsif case_id == CASE_CONTEXT_FIELDS
      checksum = checksum + Snails.logger.bench_context_fields.length
    elsif case_id == CASE_RESERVED_SCAN
      reserved = Snails::Logger::Record::RESERVED_FIELDS
      checksum = checksum + 1 if reserved.include?("snails.duration_ms")
      checksum = checksum + 1 if reserved.include?("http.request.method")
    elsif case_id == CASE_NAME_PATTERN
      pattern = Snails::Logger::Record::FIELD_PATTERN
      checksum = checksum + 1 if pattern.match?("snails.duration_ms")
      checksum = checksum + 1 if pattern.match?("http.request.method")
    elsif case_id == CASE_RENDER
      checksum = checksum + RECORD_FORMATTER.call(RECORD, Snails.logger.progname).length
    elsif case_id == CASE_FORMAT_TIME
      checksum = checksum + Snails::Logger::Formatter.format_time(Time.now).length
    elsif case_id == CASE_LINE
      checksum = checksum + LINE_FORMATTER.call(SEVERITIES[0], Time.now, "", MESSAGE).length
    elsif case_id == CASE_PID_TEXT
      checksum = checksum + Process.pid.to_s.length
    elsif case_id == CASE_LOCK
      WRITE_LOCK.synchronize do
        checksum = checksum + 1
      end
    elsif case_id == CASE_WRITE
      Snails.logger.report_local(:info, LINE)
    elsif case_id == CASE_TIME_UTC
      checksum = checksum + Time.now.utc.usec
    elsif case_id == CASE_BEGIN_REQUEST
      checksum = checksum + Snails::Logger::Context.begin_request.length
    elsif case_id == CASE_LEVEL_GATE
      checksum = checksum + 1 if Snails.logger.info?
    elsif case_id == CASE_FLOAT_TEXT
      checksum = checksum + (0.213).to_s.length + (0.0).to_s.length
    end
    i += 1
  end
  checksum
end

# Runs the case on `threads` threads and answers the wall time in ns. The
# window counts every thread's calls, so dividing by threads x iterations is
# the per-call cost including contention.
def run_round(case_id, threads)
  started = clock_ns
  workers = []
  t = 0
  while t < threads
    workers << Thread.new do
      run_iterations(case_id, ITERATIONS)
    end
    t += 1
  end
  i = 0
  while i < workers.length
    workers[i].join
    i += 1
  end
  clock_ns - started
end

def measure(case_id, threads)
  samples = []
  round = 0
  while round < ROUNDS
    elapsed = run_round(case_id, threads)
    samples << elapsed
    round += 1
  end
  samples.sort!
  wall_ns = samples[samples.length / 2]
  # Thread time: how long one thread took to finish its share. At one thread
  # this is the case's own cost; at N it also carries the wait on anything
  # shared. Calls per second is the aggregate the machine produced, so a case
  # that serializes shows the same rate at 1 and at 32 threads.
  puts format("%-40s %2d t  %9.0f ns/call  %10.0f calls/s",
              CASE_LABELS[case_id], threads,
              wall_ns.to_f / ITERATIONS,
              (ITERATIONS * threads) * 1000000000.0 / wall_ns)
end

puts "logger cost bench — output=#{OUTPUT}, rounds=#{ROUNDS}, iterations=#{ITERATIONS} per thread"
puts

t_index = 0
while t_index < THREAD_COUNTS.length
  threads = THREAD_COUNTS[t_index]
  case_id = 1
  while case_id <= 19
    measure(case_id, threads)
    case_id += 1
  end
  puts
  t_index += 1
end

puts "checksum #{run_iterations(CASE_FULL_EVENT, 1)}"
