# Tep::Scheduler -- cooperative fiber scheduler for one worker process, so a
# long-running response (SSE, long-poll, slow batch) parks instead of pinning
# the worker. Fibers park on time (`pause`) or I/O (`io_wait`, polled by
# `tick`), and only where they ask to: nothing yields at a blocking call.
module Tep
  class Scheduler
    # Mode bits for io_wait, mirroring sphttp's encoding so the C and Ruby
    # sides stay aligned.
    READ  = 1
    WRITE = 2

    # Register `f` in the scheduler's slot arrays, one slot per fiber. Slot
    # state lives in parallel typed arrays on `Tep::APP`: fiber, wake_at
    # (microseconds, -1 = ready now), io_fd / io_mode (parked fd and requested
    # bits) and io_ready. Parallel arrays keep one element type per column; a
    # single array of structs would force a poly_array.
    def self.spawn_fiber(f)
      Tep::APP.sched_fibers.push(Tep::FiberSlot.new(f))
      Tep::APP.sched_wake_at.push(-1)
      Tep::APP.sched_io_fd.push(-1)
      Tep::APP.sched_io_mode.push(0)
      Tep::APP.sched_io_ready.push(0)
      f
    end

    # `tick(poll_timeout_ms)` -- one scheduler pass: poll the I/O set, mark
    # ready fibers, then resume the soonest-due one.
    #
    # The poll must not block while some fiber is already time-due -- that wait
    # is pure latency on every hand-off to a freshly spawned fiber.
    #
    # @param poll_timeout_ms [Integer] upper bound in milliseconds for the I/O
    #   poll, forced to 0 when a fiber is already due
    # @return [Boolean] true when a fiber was resumed
    def self.tick(poll_timeout_ms)
      # Reclaim trailing dead slots, else the arrays grow once per accepted
      # connection and never shrink. Tail-only is deliberate: surviving slots
      # keep their index, so an index a caller holds across `Fiber.yield`
      # still addresses the same fiber. A dead slot in the middle is reclaimed
      # once it reaches the tail.
      i = Tep::APP.sched_fibers.length - 1
      while i >= 0 && !Tep::APP.sched_fibers[i].f.alive?
        Tep::APP.sched_fibers.delete_at(i)
        Tep::APP.sched_wake_at.delete_at(i)
        Tep::APP.sched_io_fd.delete_at(i)
        Tep::APP.sched_io_mode.delete_at(i)
        Tep::APP.sched_io_ready.delete_at(i)
        i -= 1
      end

      ms = poll_timeout_ms
      if any_time_ready
        ms = 0
      end
      poll_round(ms)

      now  = Sock.sphttp_now_us
      best = -1
      i = 0
      n = Tep::APP.sched_fibers.length
      while i < n
        if Tep::APP.sched_fibers[i].f.alive? && Tep::APP.sched_wake_at[i] <= now
          if best < 0 || Tep::APP.sched_wake_at[i] < Tep::APP.sched_wake_at[best]
            best = i
          end
        end
        i += 1
      end
      if best < 0
        return false
      end
      Tep::APP.sched_current = best
      Tep::APP.sched_wake_at[best] = -1
      Tep::APP.sched_fibers[best].f.resume
      Tep::APP.sched_current = -1
      true
    end

    # `run_until_empty` -- resume ready fibers until none can run: every fiber
    # finished or parked on a future wake or I/O. Non-blocking: no poll wait
    # between passes.
    #
    # @return [Integer] how many fibers were resumed
    def self.run_until_empty
      n = 0
      while Scheduler.tick(0)
        n += 1
      end
      n
    end

    # `run_for(seconds)` -- drain the scheduler until `seconds` elapse or every
    # fiber finishes. While nothing is runnable it blocks until the next
    # wake-up instead of spinning.
    #
    # @param seconds [Numeric] how long to drain, in seconds
    # @return [void]
    def self.run_for(seconds)
      # Bookkeeping is in microseconds (like wake_at); poll() takes ms and
      # sleep takes seconds, so convert at each call site.
      deadline = Sock.sphttp_now_us + (seconds * 1000000).to_i
      while Sock.sphttp_now_us < deadline
        if !Scheduler.tick(0)
          next_at = next_wake
          gap = deadline - Sock.sphttp_now_us
          if next_at >= 0
            tgap = next_at - Sock.sphttp_now_us
            if tgap < gap
              gap = tgap
            end
          end
          if gap < 0
            gap = 0
          end
          if any_io_waiter
            poll_round(gap / 1000)
          elsif next_at < 0
            return
          elsif gap > 0
            sleep(gap / 1000000.0)
          end
        end
      end
    end

    # `pause(seconds)` -- suspend the calling fiber until at-or-after `seconds`,
    # handing control back to the scheduler loop. Named `pause` rather than
    # `sleep` to stay distinct from `Kernel#sleep`.
    #
    # Outside a fiber it falls back to a real sleep, so the same call works at
    # top level.
    #
    # @param seconds [Numeric] how long to park, in seconds
    # @return [void]
    def self.pause(seconds)
      idx = Tep::APP.sched_current
      if idx < 0
        sleep(seconds)
        return
      end
      Tep::APP.sched_wake_at[idx] = Sock.sphttp_now_us + (seconds * 1000000).to_i
      Fiber.yield
    end

    # `io_wait(fd, mode, timeout_seconds)` -- park the calling fiber until `fd`
    # is ready for `mode` or `timeout_seconds` elapses.
    #
    # Outside a fiber it does one inline poll, so the same call works at top
    # level.
    #
    # @param fd [Integer] the descriptor to wait on
    # @param mode [Integer] readiness bits to wait for: 1 = read, 2 = write,
    #   3 = both
    # @param timeout_seconds [Numeric] how long to wait, in seconds
    # @return [Integer] the observed-ready bits, 0 on timeout
    def self.io_wait(fd, mode, timeout_seconds)
      idx = Tep::APP.sched_current
      if idx < 0
        Sock.sphttp_poll_reset
        slot = Sock.sphttp_poll_add(fd, mode)
        Sock.sphttp_poll_run(timeout_seconds * 1000)
        return Sock.sphttp_poll_ready(slot)
      end
      Tep::APP.sched_io_fd[idx]    = fd
      Tep::APP.sched_io_mode[idx]  = mode
      Tep::APP.sched_io_ready[idx] = 0
      if timeout_seconds < 0
        # A -1 wake_at reads as "ready now" to the tick picker, so a far-future
        # one parks the fiber until poll() marks it ready.
        Tep::APP.sched_wake_at[idx] = Sock.sphttp_now_us + 86400 * 1000000
      else
        Tep::APP.sched_wake_at[idx] = Sock.sphttp_now_us + (timeout_seconds * 1000000).to_i
      end
      Fiber.yield
      ready = Tep::APP.sched_io_ready[idx]
      Tep::APP.sched_io_fd[idx]    = -1
      Tep::APP.sched_io_mode[idx]  = 0
      Tep::APP.sched_io_ready[idx] = 0
      ready
    end

    # Reset the schedulable set, e.g. between tests or a restarted worker loop.
    def self.clear
      while Tep::APP.sched_fibers.length > 0
        Tep::APP.sched_fibers.delete_at(0)
        Tep::APP.sched_wake_at.delete_at(0)
        Tep::APP.sched_io_fd.delete_at(0)
        Tep::APP.sched_io_mode.delete_at(0)
        Tep::APP.sched_io_ready.delete_at(0)
      end
    end

    def self.alive_count
      n = 0
      i = 0
      total = Tep::APP.sched_fibers.length
      while i < total
        if Tep::APP.sched_fibers[i].f.alive?
          n += 1
        end
        i += 1
      end
      n
    end

    # `scheduled_context?` -- whether a scheduler-managed fiber is executing
    # right now; `tick` sets the flag just before resuming a fiber and clears it
    # after. Callers use it to choose between the blocking and the
    # fiber-yielding path.
    #
    # @return [Boolean] true inside a scheduler resume, false outside one
    def self.scheduled_context?
      Tep::APP.sched_current >= 0
    end

    # Private on purpose: `tick` and the run helpers are the entries; the
    # poll-set and wake queries are free to change without notice.

    # Build the poll set from fibers parked on I/O, poll for up to
    # `timeout_ms` (-1 = block forever, 0 = non-blocking peek), and write the
    # ready bits back. Returns the number of fds polled; 0 for an empty set.
    def self.poll_round(timeout_ms)
      Sock.sphttp_poll_reset
      slots = [-1] # slot index parallel to sched_fibers; -1 = not polled
      slots.pop
      added = 0
      i = 0
      n = Tep::APP.sched_fibers.length
      while i < n
        slot = -1
        if Tep::APP.sched_fibers[i].f.alive? &&
           Tep::APP.sched_io_fd[i] >= 0 &&
           Tep::APP.sched_io_ready[i] == 0
          slot = Sock.sphttp_poll_add(Tep::APP.sched_io_fd[i],
                                      Tep::APP.sched_io_mode[i])
          added += 1
        end
        slots.push(slot)
        i += 1
      end
      if added == 0
        return 0
      end
      Sock.sphttp_poll_run(timeout_ms)
      now = Sock.sphttp_now_us
      i = 0
      while i < n
        if slots[i] >= 0
          ready = Sock.sphttp_poll_ready(slots[i])
          if ready > 0
            Tep::APP.sched_io_ready[i] = ready
            Tep::APP.sched_wake_at[i]  = now
          end
        end
        i += 1
      end
      added
    end

    def self.next_wake
      best = -1
      i = 0
      n = Tep::APP.sched_fibers.length
      while i < n
        if Tep::APP.sched_fibers[i].f.alive?
          if best < 0 || Tep::APP.sched_wake_at[i] < Tep::APP.sched_wake_at[best]
            best = i
          end
        end
        i += 1
      end
      if best < 0
        return -1
      end
      Tep::APP.sched_wake_at[best]
    end

    def self.any_io_waiter
      i = 0
      n = Tep::APP.sched_fibers.length
      while i < n
        if Tep::APP.sched_fibers[i].f.alive? &&
           Tep::APP.sched_io_fd[i] >= 0 &&
           Tep::APP.sched_io_ready[i] == 0
          return true
        end
        i += 1
      end
      false
    end

    # True when some alive fiber's wake_at has already passed -- the signal for
    # tick() that this pass must not block in poll().
    def self.any_time_ready
      now = Sock.sphttp_now_us
      i = 0
      n = Tep::APP.sched_fibers.length
      while i < n
        if Tep::APP.sched_fibers[i].f.alive? && Tep::APP.sched_wake_at[i] <= now
          return true
        end
        i += 1
      end
      false
    end
    private_class_method :poll_round, :next_wake, :any_io_waiter, :any_time_ready
  end
end
