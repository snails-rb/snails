# Tep::BroadcastSubscription — one entry in the Tep::Broadcast registry: a
# topic name plus its output, either the connection's
# Tep::WebSocket::Driver for framed delivery or a bare fd for raw bytes.
#
# Writes go through the driver, not its fd number: a publish runs on whichever
# thread committed the record, and between copying the entry and writing, the
# connection can close and the kernel can hand its fd to the next accept. The
# driver's write lock refuses once the owner has retired it. `fd` stays for the
# raw-bytes mode and for `unsubscribe_fd`, called while the number is still
# unique to the connection.
#
# Subscriptions are fd-local, so nothing here fans out across processes.
module Tep
  class BroadcastSubscription
    attr_reader :topic   # String
    attr_reader :fd      # Integer file descriptor
    # the delivery encoding Tep::Broadcast.publish uses for this subscription.
    #
    # @return [Integer] 0 = raw bytes (Sock.sphttp_write_bytes), the
    #   default for SSE and log fan-out; 1 = WebSocket TEXT frame
    #   (Tep::WebSocket::OPCODE_TEXT); 2 = WebSocket BINARY frame
    #   (Tep::WebSocket::OPCODE_BINARY). Modes 1 and 2 route through
    #   Tep::WebSocket::Driver#write_frame, so payloads land as frames
    #   the peer accepts.
    attr_reader :mode
    attr_reader :ws      # Tep::WebSocket::Driver; the writer for modes 1 and 2

    def initialize(topic, fd, mode, ws)
      @topic = topic
      @fd    = fd
      @mode  = mode
      @ws    = ws
    end
  end
end
