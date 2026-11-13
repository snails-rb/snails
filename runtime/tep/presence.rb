# Tep::Presence — no-op stub. This runtime tracks no presence state, but
# Tep::WebSocket::Connection#dispatch_close calls `untrack_by_fd` on every socket
# close, so the name must resolve.
module Tep
  module Presence
    def self.untrack_by_fd(fd)
    end
  end
end
