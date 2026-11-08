# Consumer harness library — the app-agnostic test framework a snails
# app's harness target uses: a real-HTTP client (Response/Harness),
# assertions (Snails::Harness::IntegrationTest), per-case DB isolation,
# and an explicit case runner (HarnessRunner).
#
# Core-owned, so every app shares one copy. Off the app boot chain: the
# harness target requires it explicitly, so the server binary never
# compiles it. DB fixtures, record accessors, seeds, and contract replay
# belong to the app.
require "net/http"
require "uri"
require "json"
# The DB wiring below needs the DB adapter (`Sqlx::Database`). The harness
# target requires ../runtime/boot before this file, and the boot chain
# loads the app's config/database.rb, so it is in the graph by then.

module Snails
  module Harness
    # HTTP response wrapper — the surface a case reads.
    class Response
      attr_reader :status, :body, :headers

      def initialize(status, body, headers)
        @status = status
        @body = body
        @headers = headers
      end

      # the body as parsed JSON, or the raw body when it is not JSON.
      #
      # @return [Object, nil] the parsed value, the raw String when parsing
      #   fails, or nil for an empty body
      def parsed_body
        return nil if @body.nil? || @body.empty?

        JSON.parse(@body)
      rescue StandardError
        @body
      end
    end

    # one real HTTP request to the running server.
    #
    # @param method [Symbol] :get, :post, :put, or :delete
    # @param path [String] the request path, query string included
    # @param base_url [String] the server origin the path is requested against
    # @param params [Hash, nil] query string for :get, request body for the
    #   other verbs; nil sends none
    # @param headers [Hash, nil] plain hash of request headers
    # @param as [Symbol, nil] :json encodes the body as JSON; otherwise
    #   form-encoded
    # @return [Response] the wrapped response
    def self.request(method, path, base_url, params, headers, as)
      uri = URI(base_url)
      target = path.dup
      if params && method == :get
        query = URI.encode_www_form(params)
        target += (target.include?("?") ? "&" : "?") + query
      end
      http = Net::HTTP.new(uri.host, uri.port)
      req = request_object(method, target)
      headers.each { |k, v| req[k] = v } unless headers.nil?
      if params && method != :get
        if as == :json
          req["Content-Type"] = "application/json"
          req.body = JSON.generate(params)
        else
          req.set_form_data(params)
        end
      end
      res = http.request(req)
      Response.new(res.code.to_i, res.body, res)
    end

    # The mail capture sink, relative to this target's cwd: the runner
    # executes cases in `harness/`, directly under the spin root, so this
    # resolves to the root's `tmp/mail-capture.jsonl` — the file the
    # server's DeliveryLog writes in test mode from the same anchor. The
    # gate empties the file before boot, so it holds one run's deliveries;
    # without a gate the file is absent and the helpers answer empty.
    MAIL_LOG_PATH = "../tmp/mail-capture.jsonl"
  end

  module Harness
    # Raised by `skip` — the case macro prints `skip <name>` and moves on
    # instead of failing (a deliberate gap, not a silent pass).
    class SkipSignal < StandardError
    end

    # the bundle dispatch gate the case macro reads. The bundle runner compiles
    # every case file into one binary and runs it once per file, so each process
    # must run only the file it was started for: the entry writes
    # `$spin_test_file = <index>` before each file's require (require order is
    # the runner's index order) and the process env names the selected index.
    # Without the env (a plain `spin test <file>`) every file runs — the
    # single-file path.
    #
    # @return [Boolean] true when this process should run the cases of
    #   the file currently being required
    # @example (the bundle entry the runner generates, once per file)
    #   $spin_test_file = 1
    #   require_relative "../up_test.rb"
    def self.file_selected?
      return true if ENV["SPIN_TEST_BUNDLE"].to_s == ""
      file = $spin_test_file
      file = 0 if file.nil?
      file == ENV["SPIN_TEST_INDEX"].to_i
    end

    # Base class for a case — an app's test classes inherit it, e.g.
    # `class UpSmokeTest < Snails::Harness::IntegrationTest`. Not API-specific: it
    # is the shared surface (real HTTP + assertions) any integration case
    # uses.
    #
    # `base_url` defaults to APP_BASE_URL (the runner's live server). Hooks
    # let an app extend the base: `setup` (per-case fixtures/auth) and
    # `default_host` (the Host header its routes expect) are reopened on the
    # class, while a case class overrides `tables` with the tables to empty
    # before each case.
    class IntegrationTest
      def initialize(base_url = nil, host: nil)
        @base_url = base_url.nil? ? ENV["APP_BASE_URL"] : base_url
        @host = host.nil? ? default_host : host
        @response = nil
        reset_tables
        reset_cache
        setup
      end

      attr_reader :response

      # case declaration inside a subclass, written as
      # `test "description" do ... end`. The case runs immediately in a fresh
      # instance — spinel AOT cannot store a block's `self` — and `name` is the
      # printed name. In a bundle process the require loads every file, but only
      # the selected file's cases run (`Snails::Harness.file_selected?`), so
      # each run prints only its own file's cases.
      #
      # The selection gate wraps the body in an `if` rather than returning
      # early: an early return in a method that stores `&block` corrupts a
      # later stored block's exit under spinel AOT (`instance_exec` then
      # raises `TypeError` after the body has finished).
      #
      # @param name [String] the case description printed with `ok`, `FAIL`,
      #   or `skip`
      # @return [void]
      def self.test(name, &block)
        if Snails::Harness.file_selected?
          instance = new
          begin
            instance.instance_exec(&block)
            puts "ok #{name}"
          rescue SkipSignal => e
            puts "skip #{name}: #{e.message}"
          rescue StandardError => e
            puts "FAIL #{name}: #{e.class}: #{e.message}"
            exit 1
          end
        end
      end

      # per-case hook: runs once per fresh instance, before the case body and
      # after per-case isolation (`tables`). No-op here; an app reopens it to
      # load fixtures or seed state.
      #
      # @return [void]
      def setup
      end

      # the table names emptied before each case, so a case never sees another
      # case's writes. Default: none; a case class with DB state overrides this.
      #
      # @return [Array[String]] the table names to empty, empty by default
      # @example
      #   def tables
      #     ["widgets"]
      #   end
      def tables
        []
      end

      # the Host header sent with every request when the instance is built
      # without one. No-op (nil) here; an app reopens it with the host its
      # routes expect.
      #
      # @return [String, nil] the host, nil unless the app reopens
      def default_host
        nil
      end

      def get(path, params: nil, headers: nil)
        @response = Snails::Harness.request(:get, path, @base_url, params, with_host(headers), nil)
      end

      def post(path, params: nil, headers: nil, as: nil)
        @response = Snails::Harness.request(:post, path, @base_url, params, with_host(headers), as)
      end

      def put(path, params: nil, headers: nil, as: nil)
        @response = Snails::Harness.request(:put, path, @base_url, params, with_host(headers), as)
      end

      def delete(path, params: nil, headers: nil, as: nil)
        @response = Snails::Harness.request(:delete, path, @base_url, params, with_host(headers), as)
      end

      # pass when the status matches. Four category symbols take a range or
      # exact code: `:success` (2xx), `:redirect` (3xx), `:error` (5xx),
      # `:missing` (404 exactly). Any other symbol resolves through the shared
      # status table (`Snails::Utils::SYMBOL_TO_STATUS_CODE`), so every symbol
      # the controller's `status:` accepts works here too; an Integer is
      # compared as-is (`assert_response 415`).
      #
      # @param type [Symbol, Integer] a category symbol, any status
      #   symbol in the shared table, or the exact status code
      # @return [void]
      # @raise [RuntimeError] the status does not match, or `type` names
      #   no category and is not in the shared status table
      # @example
      #   assert_response :bad_request
      #   assert_response 415
      def assert_response(type)
        actual = @response.status
        ok = if type == :success
               actual >= 200 && actual <= 299
             elsif type == :redirect
               actual >= 300 && actual <= 399
             elsif type == :error
               actual >= 500 && actual <= 599
             elsif type == :missing
               actual == 404
             elsif type.is_a?(Integer)
               actual == type
             elsif type.is_a?(Symbol)
               code = Snails::Utils::SYMBOL_TO_STATUS_CODE[type]
               raise "unknown response type: #{type}" if code.nil?

               actual == code
             else
               raise "unknown response type: #{type}"
             end
        return if ok

        raise "assert_response #{type}: got #{actual} — #{@response.body.to_s[0, 200]}"
      end

      # pass when the two values match; the failure names both sides.
      #
      # @return [void]
      # @raise [RuntimeError] the values differ
      def assert_equal(expected, actual)
        return if expected == actual

        raise "assert_equal: expected #{expected.inspect}, got #{actual.inspect}"
      end

      # pass when the block raises the named exception (a subclass counts);
      # nothing raised or a different exception fails, and the failure names
      # what came instead.
      #
      # @param error_class [Class] the exception the block must raise
      # @return [void]
      # @raise [RuntimeError] nothing was raised, or another exception was
      # @example
      #   assert_raises(Sqlx::RecordNotFound) { User.find_by!(email: "sue@example.com") }
      def assert_raises(error_class)
        begin
          yield
        rescue error_class
          return
        rescue StandardError => e
          raise "assert_raises: expected #{error_class}, got #{e.class}: #{e.message}"
        end
        raise "assert_raises: #{error_class} not raised"
      end

      # pass when the pattern matches the actual value. A String pattern is a
      # literal substring (minitest parity: never a regexp source), so it needs
      # no escaping pass.
      #
      # @param pattern [Regexp, String] the pattern to match against
      # @param actual [String] the value being matched
      # @return [void]
      # @raise [RuntimeError] the pattern does not match
      # @example
      #   assert_match(/\d{4}/, response.body)
      def assert_match(pattern, actual)
        matched = if pattern.is_a?(String)
                    actual.to_s.include?(pattern)
                  else
                    pattern.match?(actual.to_s)
                  end
        return if matched

        raise "assert_match: expected #{actual.inspect} to match #{pattern.inspect}"
      end

      # pass when the collection holds the object; whatever `include?` answers
      # for that collection covers it (Array membership, String substring).
      #
      # @param collection [Array, String] the collection searched
      # @param object [Object] the value that must be present
      # @return [void]
      # @raise [RuntimeError] the collection does not hold the object
      # @example
      #   assert_includes response.body, "created"
      def assert_includes(collection, object)
        return if collection.include?(object)

        raise "assert_includes: #{object.inspect} not included in #{collection.inspect}"
      end

      # pass when the value is truthy; the optional message rides on the failure
      # line.
      #
      # @param value [Object] the truthy value under test
      # @param message [String, nil] extra context printed on failure
      # @return [void]
      # @raise [RuntimeError] the value is false or nil
      def assert(value, message = nil)
        return if value

        raise message.nil? ? "assert failed" : "assert failed: #{message}"
      end

      # pass when the value is nil; the failure names what was there instead.
      #
      # @param value [Object] the value under test
      # @param message [String, nil] extra context printed on failure
      # @return [void]
      # @raise [RuntimeError] the value is not nil
      def assert_nil(value, message = nil)
        return if value.nil?

        raise "assert_nil failed#{message.nil? ? "" : ": #{message}"} got=#{value.inspect}"
      end

      # pass when the value is not nil; the failure names the nil it got.
      #
      # @param value [Object] the value under test
      # @param message [String, nil] extra context printed on failure
      # @return [void]
      # @raise [RuntimeError] the value is nil
      def assert_not_nil(value, message = nil)
        return unless value.nil?

        raise message.nil? ? "assert_not_nil failed" : "assert_not_nil failed: #{message}"
      end

      # pass when the value is false or nil; the failure names what was truthy.
      #
      # @param value [Object] the value under test
      # @param message [String, nil] extra context printed on failure
      # @return [void]
      # @raise [RuntimeError] the value is truthy
      def assert_not(value, message = nil)
        return unless value

        raise "assert_not failed#{message.nil? ? "" : ": #{message}"} got=#{value.inspect}"
      end

      # pass when the two values differ; the failure names both sides, like
      # `assert_equal`.
      #
      # @param expected [Object] the value the actual must differ from
      # @param actual [Object] the value under test
      # @param message [String, nil] extra context printed on failure
      # @return [void]
      # @raise [RuntimeError] the values match
      def assert_not_equal(expected, actual, message = nil)
        return unless expected == actual

        raise "assert_not_equal failed#{message.nil? ? "" : ": #{message}"}: both were #{expected.inspect}"
      end

      # pass when `left <operator> right` holds; the failure prints the
      # comparison that did not.
      #
      # @param left [Object] the left-hand value
      # @param operator [Symbol] one of :>=, :<=, :>, :<
      # @param right [Object] the right-hand value
      # @param message [String, nil] extra context printed on failure
      # @return [void]
      # @raise [ArgumentError] the operator is not one of the four
      # @raise [RuntimeError] the comparison does not hold
      def assert_operator(left, operator, right, message = nil)
        ok = if operator == :>=
               left >= right
             elsif operator == :<=
               left <= right
             elsif operator == :>
               left > right
             elsif operator == :<
               left < right
             else
               raise ArgumentError, "assert_operator expects :>=, :<=, :> or :<, got #{operator.inspect}"
             end
        return if ok

        raise "assert_operator failed#{message.nil? ? "" : ": #{message}"} #{left.inspect} #{operator} #{right.inspect}"
      end

      # assert the block caused exactly `count` deliveries. The server is a
      # separate process, so its `ActionMailer::Base.deliveries` is unreadable
      # from here; the shared observation point is the gate's mail log
      # (`tmp/mail-capture.jsonl` under the spin root, `MAIL_LOG_PATH` from this
      # target's cwd — the file the server writes in test mode, where the
      # stamped config/environment.rb registers the capture). The engine empties
      # the file before boot, so the count is the block's before/after line
      # delta, never an absolute. Without a live gate (a bare
      # `spin test <file>`) the case skips — a mail assertion that cannot run is
      # visibly skipped, not silently green.
      #
      # @param count [Integer] the deliveries the block must cause
      # @return [void]
      # @example
      #   assert_emails 1 do
      #     post("/api/account/password", params: { email: "sue@example.com" }, as: :json)
      #   end
      def assert_emails(count)
        if ENV["APP_BASE_URL"].to_s.empty?
          raise SkipSignal, "assert_emails (no live gate — run bin/test)"
        end

        before = mail_log_entries.length
        yield
        actual = mail_log_entries.length - before
        return if actual == count

        raise "assert_emails failed: expected #{count} mail(s), got #{actual}"
      end

      # the run's recorded deliveries so far, in send order: one hash per
      # delivery with `"to"` (array), `"from"`, and `"subject"`. The gate engine
      # empties the log before boot; a case reads `emails.last` after an
      # `assert_emails` block rather than asserting absolutes.
      #
      # @return [Array[Hash]] parsed log rows; empty without a gate
      def emails
        mail_log_entries
      end

      # end the case as skipped rather than failed; raises `SkipSignal`, the
      # signal the `test` macro catches.
      #
      # @param message [String] the reason printed after the case name;
      #   "skipped" by default
      # @return [void]
      # @raise [SkipSignal] always — the case body ends here
      def skip(message = "skipped")
        raise SkipSignal, message
      end

      private

      # Read the mail capture log — `MAIL_LOG_PATH` from this target's cwd.
      # A missing file means nothing was recorded.
      def mail_log_entries
        path = Snails::Harness::MAIL_LOG_PATH
        return [] unless File.exist?(path)

        rows = []
        File.readlines(path).each do |line|
          rows << JSON.parse(line) unless line.strip.empty?
        end
        rows
      end

      # Per-case isolation — empty every declared table. Runs from
      # `initialize` before the app's `setup`, so fixtures land on a clean
      # slate.
      def reset_tables
        tables.each { |table| Sqlx::Database.exec("DELETE FROM " + table) }
      end

      # Per-case isolation — empty the process-local cache, so cached values
      # and rate-limit windows do not carry into the next case.
      def reset_cache
        Snails.cache.clear
      end

      # Merge the app's default Host into the request headers.
      def with_host(headers)
        out = {}
        headers.each { |k, v| out[k] = v } unless headers.nil?
        out["Host"] = @host unless @host.nil? || @host.empty?
        out
      end
    end

    # The Net::HTTP request object behind `Harness.request`. The verb decides
    # the class; every other argument travels on the object.
    #
    # Private on purpose: `Harness.request` is the entry; this builder is
    # free to change without notice.
    def self.request_object(method, path)
      if method == :get
        Net::HTTP::Get.new(path)
      elsif method == :post
        Net::HTTP::Post.new(path)
      elsif method == :put
        Net::HTTP::Put.new(path)
      else
        Net::HTTP::Delete.new(path)
      end
    end

    private_class_method :request_object
  end

  # Explicit case runner — spinel has no autorun, so the caller names the
  # cases and the printed summary is the `.expected` snapshot.
  module HarnessRunner
    # run one class's cases and report them: one `ok`/`FAIL` line per case, then
    # a summary.
    #
    # @param klass [Class] the case class, instantiated fresh per case
    # @param names [Array[String]] the case method names to run
    # @return [void] does not return — the process exits 0 when every
    #   case passed and 1 when any failed
    def self.run(klass, names)
      failed = 0
      names.each do |name|
        instance = klass.new
        begin
          instance.send(name)
          puts "ok #{name}"
        rescue StandardError => e
          failed += 1
          puts "FAIL #{name}: #{e.class}: #{e.message}"
        end
      end
      if failed.zero?
        puts "#{klass.name}: #{names.size} tests passed"
        exit 0
      else
        puts "#{klass.name}: #{failed} of #{names.size} tests failed"
        exit 1
      end
    end
  end

  # DB wiring for this target — the server configures its own connection in
  # main.rb, which the harness graph never loads. Done only when the gate
  # handed over an adapter source (sqlite DATABASE_PATH, or pg PG_URL):
  # the small core harness and HTTP-only apps run without a database.
  if ENV["DATABASE_PATH"] || ENV["PG_URL"]
    Sqlx::Database.configure_default!
  end
end
