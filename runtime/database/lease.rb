# The connection lease both database adapters share. A lease scope is the unit
# of connection ownership: `with_connection` opens the scope, and the first
# database access inside it checks a connection out of the adapter's pool. A
# scope that never touches the database therefore never checks one out. Nested
# scopes reuse the outer scope; a thread outside a scope falls back to the
# adapter's single connection until `require_leases!`, after which the adapter
# refuses the access instead of letting two threads share a session.
#
# The adapter supplies one hook — `lease_checkout` returns a `LeaseToken` (or
# nil before `configure`). `LeaseToken` binds the pool and position; its
# `connection` and `release` calls are the only adapter-specific mechanics.
# A pool may discard a connection mid-lease (a lost session). `release` receives
# the connection the lease bound, so the pool can tell a late release from a
# replacement at the same position. The request read cache opens when the
# connection is checked out and closes with the outermost scope.
require_relative "query_cache"

module Sqlx
  module Database
    # One checked-out pool position. The pool owns the connection array; the
    # token carries only the position, so the shared lease code never names a
    # concrete connection type (spinel types the adapter's own array
    # concretely).
    class LeaseToken
      def initialize(pool, index)
        @pool = pool
        @index = index
      end

      def connection
        @pool.conn(@index)
      end

      def release(conn, finished)
        @pool.release(@index, conn, finished)
      end
    end

    # Whether every database access now needs a `with_connection` scope. One-way,
    # per process: `Snails::Main.start` flips it before the server runs, while
    # boot code and single-fiber tests keep the fallback.
    @lease_required = false

    # run the block inside a connection lease scope and hand back its value. The
    # scope does not touch the pool by itself: the first database access checks
    # a connection out (see `ensure_connection`), so a request, job, or log
    # hand-off that never reaches the database never leases a connection. A
    # thread already inside a scope re-enters it: the outer connection and
    # request cache carry on, so a nested block can neither rebind nor unbind
    # its outer scope. Before `configure` there is nothing to lease, so the
    # block runs without a cache; a database access inside still fails loudly on
    # the absent connection.
    #
    # @return [Object] the block's value
    def self.with_connection
      return yield if in_lease?

      Thread.current[:db_lease_scope] = true
      finished = false
      begin
        result = yield
        finished = true
      ensure
        Thread.current[:db_lease_scope] = nil
        conn = Thread.current[:db_conn]
        token = Thread.current[:db_lease_token]
        Thread.current[:db_lease_token] = nil
        if !conn.nil?
          query_cache_end
          Thread.current[:db_conn] = nil
          token.release(conn, finished) unless token.nil?
        end
      end
      result
    end

    # the connection for this thread, checking one out of the pool on first use
    # inside a lease scope. Outside a scope it answers nil; the caller either
    # falls back (single-fiber contexts before `require_leases!`) or raises. A
    # scope with no database access never reaches this method, which is what
    # keeps `/up` and other no-DB requests off the pool.
    #
    # @return [untyped, nil] the leased connection, or nil outside a scope
    def self.ensure_connection
      conn = Thread.current[:db_conn]
      return conn if !conn.nil?
      return nil if Thread.current[:db_lease_scope].nil?

      token = lease_checkout
      return nil if token.nil?

      conn = token.connection
      Thread.current[:db_lease_token] = token
      Thread.current[:db_conn] = conn
      query_cache_begin
      conn
    end

    # whether this thread is inside a `with_connection` scope. The scope is open
    # even before the first database access; callers use it to avoid opening a
    # nested scope that would rebind the outer one.
    #
    # @return [Boolean] true when the thread is inside a lease scope
    def self.in_lease?
      !Thread.current[:db_lease_scope].nil? || !Thread.current[:db_conn].nil?
    end

    # require a `with_connection` scope for every database access from here on.
    # A server process (the scheduler, worker threads, and one thread per client
    # connection) may otherwise reach a shared connection another thread holds
    # mid-transaction. The fallback stays for single-fiber contexts (boot,
    # tests, one-shot dev commands).
    #
    # @return [void]
    def self.require_leases!
      @lease_required = true
    end

    private_class_method :ensure_connection
  end
end
