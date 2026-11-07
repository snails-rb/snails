require_relative "tep_core"
require_relative "url"
require_relative "net"
require_relative "streamer"
# BroadcastSubscription is needed by app.rb (which type-seeds the
# subscriber registry) and broadcast.rb.
require_relative "broadcast_subscription"
# The WebSocket stack must load before response.rb: Response#initialize
# seeds an @ws_driver field with Tep::WebSocket::Driver.new(0).
require_relative "websocket"
require_relative "request"
require_relative "response"
require_relative "parser"
require_relative "scheduler"
# Presence is a no-op stub here; WebSocket::Connection's close path calls
# Tep::Presence.untrack_by_fd.
require_relative "presence"
require_relative "broadcast"
# App owns the broadcast-subscriber registries (and the app's display name)
# on the Tep::APP singleton; broadcast.rb, cable.rb and the servers read it.
require_relative "app"
# Server helpers both server classes call (status text, refusal answers, the
# process.started record). Loaded after app.rb because the record reads
# `Tep::APP` and the app's name.
require_relative "server_shared"
require_relative "server_threaded"
# The fiber measurement server is not reachable from the app entry; the code
# stays for the 2.0 concurrency model.
require_relative "server_scheduled"

module Tep
  # Type-seeding: pin parameter types for transport methods the dispatch
  # path may not exercise from every angle.
  _tep_seed_res = Response.new
  _tep_seed_res.set_cookie("", "", str_hash)
  _tep_seed_res.start_stream(Streamer.new)
  _tep_seed_stream = Stream.new(0)
  _tep_seed_res.streamer.pump(_tep_seed_stream)
  _tep_seed_stream.write("")

  # Pin the String param type on a method nothing calls: without a
  # String-typed call site spinel defaults the param to int and the C
  # compile fails when the body uses it as a string. The call is a
  # side-effect-free read of the (empty) registry, so load time is fine.
  Tep::Broadcast.subscribers_for("")
end
