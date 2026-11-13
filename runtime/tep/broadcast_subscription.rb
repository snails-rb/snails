# Tep::BroadcastSubscription — one entry in the Tep::Broadcast registry: a topic,
# an output fd, a delivery mode, and the driver for framed delivery.
#
# Writes go through the driver, never the fd number, because the connection may
# close first and the kernel may reuse its fd for a new accept.
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
