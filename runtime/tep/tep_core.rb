module Tep
  # `display_name` — the name the server announces itself by.
  #
  # The app records its name before the server starts, so a binary started
  # without one falls back to its file name.
  #
  # @return [String] `Tep::APP.name`, or `File.basename($PROGRAM_NAME)` when
  #   that name is empty
  def self.display_name
    n = Tep::APP.name
    n.length > 0 ? n : File.basename($PROGRAM_NAME)
  end

  # `os_workers_desc` — the banner's line about OS workers.
  #
  # The runtime exposes no accessor for the effective count, so the banner
  # reports the declaration, never a measurement.
  #
  # @return [String] "N (SPINEL_WORKERS)" when the variable is set, otherwise
  #   "one per core (SPINEL_WORKERS=N to cap)"
  def self.os_workers_desc
    w = ENV["SPINEL_WORKERS"] || ""
    if w.length == 0
      "one per core (SPINEL_WORKERS=N to cap)"
    else
      w + " (SPINEL_WORKERS)"
    end
  end

  # `processes_desc(workers)` — the banner's line about worker processes;
  # `--workers N` preforks N processes, so the flag is named only when it is
  # in effect.
  #
  # @param workers [Integer] the requested `--workers N` count
  # @return [String] "N (--workers)" when more than one process, else "1"
  def self.processes_desc(workers)
    workers > 1 ? workers.to_s + " (--workers)" : "1"
  end

  def self.str_hash
    # Missing-key reads must return "" — the tep readers assume it
    # (parser.rb cookie handling, request.rb Connection/Content-Type).
    Hash.new("")
  end

  # Holder for a Fiber so the cooperative scheduler (Tep::Scheduler, which the
  # measurement-only server drives) can keep them in a typed array.
  # Spinel's `[Fiber.new { ... }]` array literal infers IntArray (Fiber is
  # a built-in pointer type, not a user class spinel tracks via PtrArray),
  # so a one-attribute wrapper class is the cheapest homogeneous container.
  class FiberSlot
    attr_accessor :f
    def initialize(f)
      @f = f
    end
  end

  # A canonical no-op fiber body, used to type-seed Fiber-bearing
  # collections without running anything user-visible.
  def self.seed_fiber_noop
    0
  end

  # Shutdown hook: the server's shutdown paths call it after the accept loop
  # breaks on SIGTERM/SIGINT.
  #
  # With TEP_GC_STAT=1 it prints the collector's attestation. `remembered`
  # and `remembered_peak` are what make the number evidence: a green
  # compare cannot tell "the write barrier held" from "nothing was ever
  # marked", and remembered_peak separates them (0 with the generational
  # mark off, non-zero with it on and a live remembered set). `full_runs`
  # does not — it counts full SWEEPS, not marks.
  def self.on_shutdown
    v = ENV["TEP_GC_STAT"] || ""
    if v != "" && v != "0"
      g = GC.stat
      puts "tep: GC.stat cycle=" + g["cycle"].to_s +
           " full_runs=" + g["full_runs"].to_s +
           " remembered=" + g["remembered"].to_s +
           " remembered_peak=" + g["remembered_peak"].to_s
      $stdout.flush
    end
  end

  # `str_find(s, needle, start)` — naive substring search returning the
  # position of `needle` in `s` starting from `start`.
  #
  # It answers an int rather than `String#index`'s int|nil: callers compare
  # with `if x < 0`, and an int comparison cannot narrow against an int|nil.
  #
  # @param s [String] the text to search
  # @param needle [String] the substring to look for
  # @param start [Integer] the offset to start at
  # @return [Integer] the position of `needle`, or -1 when not found
  def self.str_find(s, needle, start)
    nlen = needle.length
    slen = s.length
    pos = start
    while pos <= slen - nlen
      if s[pos, nlen] == needle
        return pos
      end
      pos += 1
    end
    -1
  end
end
