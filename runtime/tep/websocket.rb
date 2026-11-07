# Tep::WebSocket -- RFC 6455 WebSocket support.
#
# A handler validates the upgrade with Handshake.check, then calls
# `res.start_websocket(accept_key, driver)`; the server writes the 101
# head and hands the connection to Connection's recv loop. That loop
# parks for the connection's lifetime, so only Tep::Server::Threaded
# serves it -- the fiber server answers an upgrade with a 501.
module Tep
  module WebSocket
    # RFC 6455 §5.2 opcode values.
    OPCODE_CONTINUATION = 0
    OPCODE_TEXT         = 1
    OPCODE_BINARY       = 2
    OPCODE_CLOSE        = 8
    OPCODE_PING         = 9
    OPCODE_PONG         = 10

    # RFC 6455 §7.4 close codes.
    CLOSE_NORMAL          = 1000
    CLOSE_GOING_AWAY      = 1001
    CLOSE_PROTOCOL_ERROR  = 1002
    CLOSE_UNSUPPORTED     = 1003
    CLOSE_INVALID_UTF8    = 1007
    CLOSE_POLICY_VIOLATION = 1008
    CLOSE_MESSAGE_TOO_BIG = 1009

    # Default frame-size cap, per driver (`Driver#set_max_frame_size`):
    # bounded so an oversized frame closes with 1009 instead of OOM-ing
    # the worker.
    DEFAULT_MAX_FRAME = 16 * 1024 * 1024
  end
end

require_relative "websocket/frame"
require_relative "websocket/handshake"
require_relative "websocket/driver"
require_relative "websocket/connection"
