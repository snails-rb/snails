# Tep::Streamer — chunked-response writer: subclass and override `pump(out)`,
# where each `out.write` sends one chunk. `pump` runs to completion, so a stream
# holds the connection until it finishes.
#
# This subclass API replaces blocks, which spinel cannot pass into the framework.
module Tep
  class Streamer
    def pump(out)
      # default no-op; subclasses override
    end
  end

  # Per-request handle the user's `pump` writes to. Wraps the client fd so
  # each `out.write(s)` becomes one chunked frame.
  class Stream
    attr_accessor :fd

    def initialize(fd)
      @fd = fd
    end

    def write(s)
      Sock.sphttp_write_chunk(@fd, s)
    end
  end
end
