# Tep::Broadcast — in-process fan-out.
#
# A registry of (topic, fd, mode) subscriptions on the Tep::APP singleton, and
# `publish`, which writes a payload to every fd subscribed to a topic. WebSocket
# subscribers get a framed message; mode 0 gets raw bytes for SSE or log fan-out.
#
# Connections are green threads, so subscribe, unsubscribe, and publish race on
# the registry: every read and write takes `Tep::APP.broadcast_lock`, and
# `publish` copies the matches out under the lock and writes after dropping it,
# because a write to a full buffer parks the thread.
#
# A WebSocket subscriber is written through its Driver, never by fd number: the
# connection can close between the copy and the write, and its number can
# already belong to the next accept. Delivery is process-local; there is no
# cross-worker backend.
module Tep
  module Broadcast
    # `subscribe(topic, fd)` — register `fd` for raw-bytes delivery on
    # `topic`.
    #
    # @return [Integer] the subscription's index at the time of the push,
    #   for `unsubscribe`; the WS path unsubscribes by fd on close instead
    def self.subscribe(topic, fd)
      sub = Tep::BroadcastSubscription.new(
        topic, fd, 0, Tep::WebSocket::Driver.new(fd))
      n = 0
      Tep::APP.broadcast_lock.synchronize do
        subs = Tep::APP.broadcast_subs
        subs.push(sub)
        n = subs.length - 1
      end
      n
    end

    # `subscribe_ws(topic, ws)` — register a WebSocket connection on
    # `topic`; payloads go out as TEXT frames through its driver.
    #
    # @param ws [Tep::WebSocket::Driver] the connection's driver
    # @return [Integer] the subscription's index at the time of the push
    def self.subscribe_ws(topic, ws)
      sub = Tep::BroadcastSubscription.new(
        topic, ws.fd, Tep::WebSocket::OPCODE_TEXT, ws)
      n = 0
      Tep::APP.broadcast_lock.synchronize do
        subs = Tep::APP.broadcast_subs
        subs.push(sub)
        n = subs.length - 1
      end
      n
    end

    # `unsubscribe(sub_id)` — drop the subscription at `sub_id`; an
    # out-of-range index is a no-op.
    #
    # @param sub_id [Integer] the index `subscribe` returned
    # @return [void]
    def self.unsubscribe(sub_id)
      Tep::APP.broadcast_lock.synchronize do
        subs = Tep::APP.broadcast_subs
        if sub_id >= 0 && sub_id < subs.length
          subs.delete_at(sub_id)
        end
      end
    end

    # `unsubscribe_topic_fd(topic, fd)` — drop every subscription of `fd`
    # to `topic`; the walk runs back to front so a `delete_at` index
    # stays valid mid-loop.
    #
    # @return [Integer] the number of subscriptions dropped
    def self.unsubscribe_topic_fd(topic, fd)
      dropped = 0
      Tep::APP.broadcast_lock.synchronize do
        subs = Tep::APP.broadcast_subs
        i = subs.length - 1
        while i >= 0
          if subs[i].fd == fd
            if subs[i].topic == topic
              subs.delete_at(i)
              dropped += 1
            end
          end
          i -= 1
        end
      end
      dropped
    end

    # `unsubscribe_fd(fd)` — drop every subscription whose fd matches.
    #
    # The WebSocket on-close path calls it before the fd is closed, while
    # its number still names only that connection.
    #
    # @return [Integer] the number of subscriptions dropped
    def self.unsubscribe_fd(fd)
      dropped = 0
      Tep::APP.broadcast_lock.synchronize do
        subs = Tep::APP.broadcast_subs
        i = subs.length - 1
        while i >= 0
          if subs[i].fd == fd
            subs.delete_at(i)
            dropped += 1
          end
          i -= 1
        end
      end
      dropped
    end

    # `publish(topic, payload)` — write `payload` to every fd subscribed
    # to `topic`.
    #
    # @return [Integer] the number of subscriptions matched, not the
    #   number of successful writes: a closed fd still counts as matched
    #   (the underlying write returns -1 silently on it). An app that
    #   needs delivery confirmation tracks its own ack channel.
    def self.publish(topic, payload)
      publish_local_only(topic, payload)
    end

    # `subscriber_count()` — how many subscriptions the registry holds.
    #
    # @return [Integer] the total across all topics, for diagnostics
    def self.subscriber_count
      n = 0
      Tep::APP.broadcast_lock.synchronize do
        n = Tep::APP.broadcast_subs.length
      end
      n
    end

    # `subscribers_for(topic)` — count the subscriptions on one topic;
    # an O(n) walk over a registry that stays small in practice.
    #
    # @return [Integer] the number of subscriptions on `topic`
    def self.subscribers_for(topic)
      n = 0
      Tep::APP.broadcast_lock.synchronize do
        subs = Tep::APP.broadcast_subs
        i = 0
        while i < subs.length
          if subs[i].topic == topic
            n += 1
          end
          i += 1
        end
      end
      n
    end

    # `clear()` — drop every subscription, for resetting between test
    # cases and for an app that needs a full reset (graceful shutdown).
    #
    # @return [Integer] the number of subscriptions dropped
    def self.clear
      n = 0
      Tep::APP.broadcast_lock.synchronize do
        subs = Tep::APP.broadcast_subs
        n = subs.length
        subs.clear
      end
      n
    end

    # Local fan-out. The matching subscriptions are copied out under the
    # lock; the writes happen outside it (see the module comment).
    #
    # Branches on each subscription's `mode`:
    #   * mode 0 -> raw bytes via Sock.sphttp_write_bytes, for SSE / log
    #     fan-out / non-framed consumers.
    #   * mode != 0 -> WebSocket frame via the subscriber's
    #     Tep::WebSocket::Driver#write_frame, with the mode value as the
    #     WS opcode (1=TEXT, 2=BINARY). A retired driver refuses the write
    #     (-1), which still counts as matched.
    def self.publish_local_only(topic, payload)
      matched = []
      Tep::APP.broadcast_lock.synchronize do
        subs = Tep::APP.broadcast_subs
        i = 0
        while i < subs.length
          if subs[i].topic == topic
            matched.push(subs[i])
          end
          i += 1
        end
      end
      i = 0
      while i < matched.length
        sub = matched[i]
        if sub.mode == 0
          # write_bytes, not write_str: write_str is strlen-terminated and a
          # raw payload is not guaranteed NUL-free.
          Sock.sphttp_write_bytes(sub.fd, payload, payload.bytesize)
        else
          sub.ws.write_frame(sub.mode, payload)
        end
        i += 1
      end
      matched.length
    end

    # Private on purpose: `publish` is the entry; the local fan-out is free
    # to change without notice.
    private_class_method :publish_local_only
  end
end
