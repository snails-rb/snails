# Tep::Presence — no-op stub. This runtime tracks no presence state, but
# Tep::WebSocket::Connection#dispatch_close calls `untrack_by_fd` on every socket
# close, so the name must resolve.
#
# @api internal
module Tep
  module Presence
    # Not app API: only the internal WebSocket close path calls it.
    #
    # @api internal
    def self.untrack_by_fd(fd)
    end
  end
end
