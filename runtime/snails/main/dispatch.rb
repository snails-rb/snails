# request path — route table, controller params, and the API-only dispatch
# pipeline. Loaded by `runtime/snails/main.rb` before `main/server.rb`.
module Snails
  module Main
    # the composed route table, built once on first use.
    #
    # The app's `config/routes.rb` declares `Snails::RouteTable.table`; it is
    # memoized because `Snails::RouteTable.table` constructs every Route on each
    # call.
    #
    # @return [Array<ActionDispatch::Router::Route>] the app's routes
    def self.route_table
      @route_table ||= Snails::RouteTable.table
    end

    # the controller's params: body fields, the query string over them, and the
    # route's path captures over both, each half nested by
    # `ActionDispatch::ParamBuilder`.
    #
    # Multipart and JSON fields are flattened by name, so a repeated field keeps
    # its last value; urlencoded and query params keep every value.
    #
    # @param req [Tep::Request] the parsed request
    # @param path_params [Hash{String => String}] the router's captures
    # @return [Hash{String => Object}, nil] nil when the input is malformed
    #   (a body the runtime could not parse, a bad %-escape, invalid UTF-8,
    #   nesting too deep, or a name used as both an Array and a Hash); the
    #   dispatcher answers 400.
    def self.request_params(req, path_params)
      return nil if req.body_parse_failed?
      query = ActionDispatch::ParamBuilder.from_query_string(req.raw_query)
      return nil if query.nil?
      body = {}
      if req.form?
        body = ActionDispatch::ParamBuilder.from_query_string(req.raw_body)
      elsif req.multipart? || req.json?
        keys = []
        values = []
        present = []
        req.body_fields.each do |k, v|
          keys.push(k)
          values.push(v)
          present.push(true)
        end
        body = ActionDispatch::ParamBuilder.build(keys, values, present)
      end
      return nil if body.nil?
      out = body
      query.each { |k, v| out[k] = v }
      path_params.each { |k, v| out[k] = v }
      out
    end

    # the default request pipeline called by `Tep::App#dispatch` for every
    # request: match, wire the typed request, run the controller, and copy
    # status/body/content-type back. API-only: `request_format` defaults to
    # JSON, and a route miss or malformed params returns the same JSON an app's
    # endpoints do; a controller's `Sqlx::RecordNotFound` becomes a JSON 404,
    # and a required parameter the client did not send becomes a JSON 400.
    #
    # A HEAD request matches the GET route it mirrors and reaches the action
    # as HEAD; the server sends that response's status and headers without
    # the message body.
    #
    # @param req [Tep::Request] the parsed request
    # @param res [Tep::Response] the response to fill
    # @return [void]
    def self.dispatch(req, res)
      # Under RH_SQL_TRACE each request line brackets its queries, so a trace
      # reader can attribute each SQL line to the request that ran it.
      if Sqlx::Database.sql_trace?
        $stderr.puts "-- " + req.verb + " " + req.path
      end

      request_path = req.path
      # HEAD is routed as the GET it mirrors — the same row, the same status
      # and headers. The request keeps its own verb, so `request.head?` and
      # the request log still say HEAD; only the route lookup changes.
      match_verb = req.verb == "HEAD" ? "GET" : req.verb
      matched = ActionDispatch::Router.match(match_verb, request_path, Snails::Main.route_table)
      if matched.nil?
        res.status = 404
        res.body = ActionController::JsonRender.encode({ "error" => "not_found" })
        res.headers["Content-Type"] = "application/json; charset=utf-8"
        return
      end
      params = Snails::Main.request_params(req, matched.path_params)
      if params.nil?
        res.status = 400
        res.body = ActionController::JsonRender.encode({ "error" => "bad_request" })
        res.headers["Content-Type"] = "application/json; charset=utf-8"
        return
      end
      controller = matched.controller.new
      controller.params = params
      controller.path_parameters = matched.path_params
      # Wire the typed request actions read. Every parsed header is copied into
      # the request's internal env store, so `request.headers` reads the full
      # set and an absent header stays absent (nil, not an empty string).
      # `ActionController::Current` carries the same objects to code without the
      # controller instance; its action scope closes in the ensure below.
      user_agent = req.req_headers.fetch("user-agent", "")
      env = {}
      req.req_headers.each do |name, value|
        env[ActionDispatch::Http::Headers.env_key(name)] = value
      end
      request_obj = ActionDispatch::Request.new(env)
      request_obj.request_method = req.verb
      request_obj.path = request_path
      qm = req.raw_path.index("?")
      request_obj.query_string = req.raw_path[qm + 1, req.raw_path.length].to_s unless qm.nil?
      request_obj.remote_ip = req.remote_host
      request_obj.referer = req.req_headers.fetch("referer", "")
      request_obj.host = req.req_headers.fetch("host", "localhost")
      request_obj.body = req.raw_body
      request_obj.user_agent = user_agent
      controller.request = request_obj
      controller.request_format = matched.req_format.nil? ? :json : matched.req_format
      # The request line's matched fields. `Tep::App#dispatch` owns the
      # line itself (it also knows the duration), so this path reports
      # what it matched rather than writing a line per action.
      Snails::Logger::Context.controller = controller.class.name
      Snails::Logger::Context.action = matched.action.to_s
      Snails::Logger::Context.format = controller.request_format.to_s
      begin
        ActionController::Current.request = request_obj
        ActionController::Current.controller = controller
        controller.process_action(matched.action)
      rescue Sqlx::RecordNotFound
        res.status = 404
        res.body = ActionController::JsonRender.encode({ "error" => "not_found" })
        res.headers["Content-Type"] = "application/json; charset=utf-8"
        return
      rescue Sqlx::CastError
        # A condition value that cannot be cast to the column type is a
        # malformed request, not a server failure — "1-welcome" on an integer
        # id answers 400 instead of reaching the driver as text or becoming a
        # 500. Apps rescue the same class to answer with their own body.
        res.status = 400
        res.body = ActionController::JsonRender.encode({ "error" => "bad_request" })
        res.headers["Content-Type"] = "application/json; charset=utf-8"
        return
      rescue ActionController::ParameterMissing
        # A required parameter the client did not send is the client's
        # error, not the server's — without this the exception reaches the
        # server as a 500. Apps rescue the same class to answer with their
        # own body; this is the default.
        res.status = 400
        res.body = ActionController::JsonRender.encode({ "error" => "bad_request" })
        res.headers["Content-Type"] = "application/json; charset=utf-8"
        return
      ensure
        ActionController::Current.request = nil
        ActionController::Current.controller = nil
      end

      res.status = controller.status
      res.body = controller.body
      res.headers["Location"] = controller.location unless controller.location.nil?
      # A render that named its own type carries it; the html default is left
      # to tep.
      if controller.content_type != "text/html; charset=utf-8"
        res.headers["Content-Type"] = controller.content_type
      end
      # Headers the action set besides `Location`. A nil value means the app
      # unset it, so it is not written.
      controller.headers.each do |k, v|
        res.headers[k] = v unless v.nil?
      end
    end
  end
end
