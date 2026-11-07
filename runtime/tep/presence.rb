# Tep::Presence — no-op stub.
#
# This runtime tracks no presence state, but
# Tep::WebSocket::Connection#dispatch_close calls Tep::Presence.untrack_by_fd
# on every socket close, so the name has to resolve. An fd is not tracked
# here, so the call does nothing.
module Tep
  module Presence
    def self.untrack_by_fd(fd)
    end
  end
end
