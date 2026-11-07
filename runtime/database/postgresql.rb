# Primitive Sqlx::Database surface — PostgreSQL via libpq FFI. The sibling of
# runtime/database/sqlite.rb: same `module Sqlx::Database` contract, documented
# at the head of that file. Everything outside that high-level list is private.
#
# The app-owned config/database.rb requires this file, so spinel's static graph
# reaches this backend only; a SQLite app never loads it.
#
# This file emits no DDL — the schema belongs to the application's deployment
# (`owns_schema?` answers false; the server never runs DDL). A per-process pool
# of connections: one libpq connection serves one lease at a time, so two
# concurrent PQexec calls never share a session. A PGresult is a client-side
# copy, so rows are read after the lease's statement returns. A connection that
# fails during a statement is dropped from the pool; a later checkout that
# finds no free connection opens a replacement. A request-scoped read cache
# holds SELECT results for the duration of a `with_connection` scope — it opens
# when the first database access checks a connection out; writes and DDL
# invalidate it.
# The cache itself is the shared store in
# `runtime/database/query_cache.rb`; this adapter's key is the statement as
# executed (bind values substituted). There is no statement cache — statement
# preparation is per-call and finalization frees.
#
# Two SQLite spellings are shimmed at this boundary: a `sqlite_sequence`
# delete becomes an identity-sequence reset, and booleans render as '1'/'0',
# a literal PostgreSQL coerces for BOTH boolean and integer columns.
#
# The lease engine (`with_connection`/`require_leases!`) lives in
# `database/lease.rb` and is shared with the SQLite sibling; this file
# supplies the checkout hook and its connection pool.

require_relative "lease"

# This file defines `Sqlx::Database`; `runtime/sqlx` owns the rest of it.
module Sqlx
  module Database
    # Bare-metal libpq FFI bindings. Only the surface the contract needs — every
    # sqlite3_* call in the sibling has a PQ* answer or a documented shim.
    module Libpq
      ffi_lib "pq"

      # ExecStatusType — PQresultStatus results. Macros in libpq's header, hence
      # ffi_const values.
      ffi_const :PGRES_EMPTY_QUERY, 0
      ffi_const :PGRES_COMMAND_OK,  1
      ffi_const :PGRES_TUPLES_OK,   2
      ffi_const :PGRES_FATAL_ERROR, 7

      # PQstatus: CONNECTION_OK == 0.
      ffi_const :CONNECTION_OK, 0

      # pg_type OIDs — this adapter's dispatch table, where sqlite dispatches on
      # the row's storage class. Types not listed here (text, varchar, timestamp,
      # date, json/jsonb) read as their raw text, which is what sqlite's TEXT
      # storage hands back.
      ffi_const :BOOLOID,     16
      ffi_const :INT8OID,     20
      ffi_const :INT2OID,     21
      ffi_const :INT4OID,     23
      ffi_const :OIDOID,      26
      ffi_const :FLOAT4OID,  700
      ffi_const :FLOAT8OID,  701
      ffi_const :NUMERICOID, 1700

      # PQresultErrorField field codes. `PG_DIAG_SQLSTATE` is 'C' in libpq's
      # header, the five-character SQLSTATE of a failed result.
      ffi_const :PG_DIAG_SQLSTATE, 67

      ffi_func :PQconnectdb,          [ :str ],             :ptr
      ffi_func :PQstatus,             [ :ptr ],             :int
      ffi_func :PQerrorMessage,       [ :ptr ],             :str
      # PQfinish / PQclear are `void` in C, declared :int with the return dropped:
      # this FFI type set has no :void.
      ffi_func :PQfinish,             [ :ptr ],             :int
      ffi_func :PQexec,               [ :ptr, :str ],       :ptr
      ffi_func :PQresultStatus,       [ :ptr ],             :int
      ffi_func :PQresultErrorMessage, [ :ptr ],             :str
      ffi_func :PQresultErrorField,   [ :ptr, :int ],       :str
      ffi_func :PQclear,              [ :ptr ],             :int
      ffi_func :PQntuples,            [ :ptr ],             :int
      ffi_func :PQnfields,            [ :ptr ],             :int
      ffi_func :PQfname,              [ :ptr, :int ],       :str
      ffi_func :PQgetvalue,           [ :ptr, :int, :int ], :str
      ffi_func :PQgetisnull,          [ :ptr, :int, :int ], :int
      ffi_func :PQftype,              [ :ptr, :int ],       :int
      ffi_func :PQcmdTuples,          [ :ptr ],             :str
    end

    # One SELECT's execution state. NOT executed at prepare: `pending` stays true
    # until first use, so a bind_* that follows prepare still lands in the SQL sent
    # to the server. Each prepare yields a FRESH object, so two interleaved readers
    # of the same SQL never alias (the sqlite sibling's stmt cache hands both the
    # same handle).
    class PgStmt
      attr_accessor :sql, :params, :res, :row, :pending, :dead, :ncols

      def initialize(sql)
        @sql = sql
        @params = []
        @res = nil
        @row = -1
        @pending = true
        @dead = false
        @ncols = 0
      end
    end

    # One libpq connection plus the session values this adapter answers from.
    # `@changes` belongs to the connection, not the process: a second session's
    # write must not overwrite the count a caller reads back. `lastval()` is the
    # connection's own last sequence value, so `last_insert_rowid` reads it
    # through the same connection the INSERT ran on.
    class PgConnection
      def initialize(conninfo)
        @dbh = Libpq.PQconnectdb(conninfo)
        if Libpq.PQstatus(@dbh) != Libpq::CONNECTION_OK
          msg = Libpq.PQerrorMessage(@dbh)
          Libpq.PQfinish(@dbh)
          raise Sqlx::ConnectionFailed, "Sqlx::Database: PG connect failed: " + msg
        end
        @changes = 0
        @index = -1
        @closed = false
        res = Libpq.PQexec(@dbh, "SET TimeZone TO 'UTC'")
        status = Libpq.PQresultStatus(res)
        message = Libpq.PQresultErrorMessage(res)
        Libpq.PQclear(res)
        if status != Libpq::PGRES_COMMAND_OK
          Libpq.PQfinish(@dbh)
          raise Sqlx::ConnectionFailed, "Sqlx::Database: PG session setup failed: " + message
        end
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        @opened_at = now
        @last_used_at = now
      end

      def dbh
        if @closed
          raise Sqlx::ConnectionFailed, "Sqlx::Database: connection is closed"
        end
        @dbh
      end

      # The pool position this connection occupies. The position is stable for
      # the connection's life: a replacement connection opens at the same
      # index, so a lease token never has to be renumbered.
      def index
        @index
      end

      # Attach this connection to the pool position `index`. The pool calls
      # this once when the connection joins `@conns`; `discard` reads `index`
      # to find the position again. A negative position is not in the pool, so
      # reject it here instead of letting the discard lookup miss.
      def attach_to_position(index)
        if !index.is_a?(Integer) || index < 0
          raise ArgumentError, "Sqlx::Database: connection position must be a non-negative Integer, got " + index.inspect
        end
        @index = index
      end

      def changes
        if @closed
          raise Sqlx::ConnectionFailed, "Sqlx::Database: connection is closed"
        end
        @changes
      end

      def changes=(value)
        @changes = value
      end

      # Record the pool release time; the next checkout measures idleness from
      # it. The pool calls this when it returns the connection to the free list.
      def mark_used(now)
        @last_used_at = now
      end

      # Whether this connection may be handed to a checkout: inside the idle and
      # lifetime bounds, and alive to a `SELECT 1` ping. The ping is driver
      # plumbing, not app SQL, so it is not recorded in the query trace or the
      # request's DB time.
      def usable?(now, idle_timeout_seconds, max_lifetime_seconds)
        return false if max_lifetime_seconds > 0 && age_seconds(now) > max_lifetime_seconds
        return false if idle_timeout_seconds > 0 && idle_seconds(now) > idle_timeout_seconds
        return false if Libpq.PQstatus(dbh) != Libpq::CONNECTION_OK

        res = Libpq.PQexec(dbh, "SELECT 1")
        ok = Libpq.PQresultStatus(res) == Libpq::PGRES_TUPLES_OK
        Libpq.PQclear(res)
        ok
      rescue Sqlx::ConnectionFailed
        false
      end

      def close
        return if @closed
        Libpq.PQfinish(@dbh)
        @closed = true
      end

      # Seconds since this connection was opened.
      def age_seconds(now)
        now - @opened_at
      end

      # Seconds since the pool last released this connection.
      def idle_seconds(now)
        now - @last_used_at
      end

      private :age_seconds, :idle_seconds
    end

    # A lazy pool of libpq connections. Connections open on first checkout, not
    # in `configure`: a prefork child must not inherit the parent's sockets, and
    # the boot probe already proved the conninfo is reachable. The pool is the
    # concurrency boundary — one connection is leased to one thread, so libpq's
    # single-statement-at-a-time rule holds without a process-wide lock.
    #
    # Pool state: `@conns[i]` is a live connection, or nil while position i
    # waits for a replacement; `@free` holds positions whose connection is live
    # and idle; `@vacant` holds positions whose connection is gone; `@opening`
    # counts positions reserved for an open in progress. A dead lease token and
    # the replacement at its position can be outstanding together — `release`
    # identifies the connection, not only the position.
    #
    # A checkout validates the leased connection (idle and lifetime bounds plus
    # a `SELECT 1` ping) before handing it to the caller; a failed check
    # discards that connection and leases again.
    class PgPool
      # How long a checkout may wait for a free connection. A request that
      # cannot get one fails loudly instead of parking behind a long
      # transaction; the knob is `checkout_timeout`.
      CHECKOUT_TIMEOUT_SECONDS = 5.0

      # A connection idle longer than this is replaced at checkout rather than
      # reused. `idle_timeout` disables it at 0. The bound is
      # applied at checkout, not by a background reaper.
      DEFAULT_IDLE_TIMEOUT_MS = 300000

      # A connection older than this is replaced at checkout. HikariCP calls the
      # knob `maxLifetime`; 0 disables it.
      DEFAULT_MAX_LIFETIME_MS = 1800000

      def initialize(conninfo, size)
        if size < 1
          raise ArgumentError, "Sqlx::Database: pool_size must be at least 1, got " + size.to_s
        end
        @conninfo = conninfo
        @size = size
        @timeout_seconds = CHECKOUT_TIMEOUT_SECONDS
        ev = ENV["DATABASE_POOL_TIMEOUT_MS"]
        if !ev.nil? && ev != ""
          @timeout_seconds = ev.to_f / 1000.0
        end
        @idle_timeout_seconds = env_seconds("DATABASE_IDLE_TIMEOUT_MS", DEFAULT_IDLE_TIMEOUT_MS)
        @max_lifetime_seconds = env_seconds("DATABASE_MAX_LIFETIME_MS", DEFAULT_MAX_LIFETIME_MS)
        @conns = []
        @free = []
        @vacant = []
        @opening = 0
        @lock = Mutex.new
        @cv = ConditionVariable.new
      end

      def conn(idx)
        @conns[idx]
      end

      # The fallback connection for single-fiber contexts before
      # `require_leases!`: answer position 0, opening it on first use. The
      # position stays in the free list, so a later lease can take it once the
      # server requires leases (the fallback path is gone by then). A failed
      # connection at position 0 is repaired here too — the fallback has no
      # lease to ask for a replacement. The open runs outside `@lock`, like
      # `lease`: no caller may wait behind DNS/TCP. Two fallback callers are
      # outside the single-fiber contract, but the race is closed anyway — the
      # loser closes its extra connection and answers the repaired one.
      def first
        existing = nil
        @lock.synchronize do
          if @conns.length > 0 && !@conns[0].nil?
            existing = @conns[0]
          end
        end
        return existing if !existing.nil?

        conn = PgConnection.new(@conninfo)
        extra = nil
        @lock.synchronize do
          if @conns.length == 0
            conn.attach_to_position(0)
            @conns.push(conn)
            @free.push(0)
            @cv.signal
          elsif @conns[0].nil?
            conn.attach_to_position(0)
            @conns[0] = conn
            @vacant.delete(0)
            @free.push(0) unless @free.include?(0)
            @cv.signal
          else
            extra = conn
            conn = @conns[0]
          end
        end
        extra.close if !extra.nil?
        conn
      end

      # `checkout()` — lease a connection, prove it usable, and answer the lease
      # token. A failed check discards the connection and retries the checkout
      # once; the retry is a checkout retry, not a statement retry.
      #
      # @return [LeaseToken] the checked-out connection's token
      # @raise [Sqlx::ConnectionTimeout] no connection became free in time
      # @raise [Sqlx::ConnectionFailed] no healthy connection could be leased
      def checkout
        attempts = 0
        while attempts < 2
          idx = lease
          conn = @conns[idx]
          now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          if !conn.nil? && conn.usable?(now, @idle_timeout_seconds, @max_lifetime_seconds)
            return LeaseToken.new(self, idx)
          end
          discard(conn) if !conn.nil?
          attempts += 1
        end
        raise Sqlx::ConnectionFailed, "Sqlx::Database: no healthy pooled PostgreSQL connection after " + attempts.to_s + " attempts"
      end

      # `release(idx, conn, finished)` — the shared lease token's release hook.
      # `finished` is unused here: this adapter has no statement cache to trim.
      # The position is only returned when it still holds the same connection; a
      # connection discarded mid-statement has already left the pool, and its
      # position waits for a later checkout that finds no free connection.
      def release(idx, conn, finished)
        @lock.synchronize do
          if idx >= 0 && idx < @conns.length && @conns[idx] == conn
            conn.mark_used(Process.clock_gettime(Process::CLOCK_MONOTONIC))
            @free.push(idx)
            @cv.signal
          end
        end
      end

      # `discard(conn)` — remove a failed connection. The position stays vacant
      # and is refilled by a later checkout that finds no free connection; the
      # current lease's release is a no-op because its connection no longer
      # occupies the position. Closing happens outside the lock.
      def discard(conn)
        discarded = false
        @lock.synchronize do
          idx = conn.index
          if idx >= 0 && idx < @conns.length && @conns[idx] == conn
            @conns[idx] = nil
            @free.delete(idx)
            @vacant.push(idx)
            @cv.signal
            discarded = true
          end
        end
        conn.close if discarded
      end

      def close_all
        i = 0
        while i < @conns.length
          conn = @conns[i]
          if !conn.nil?
            conn.close
          end
          i += 1
        end
      end

      # Lease one connection position: a free connection, a vacant position
      # whose replacement opens outside the lock, or a new position while the
      # pool is under its size. Parks the caller when every position is leased
      # or opening; the wait is bounded by `DATABASE_POOL_TIMEOUT_MS`.
      #
      # Opening a connection can block on DNS/TCP, so it must not run under
      # `@lock`: a checkin would wait behind it and free connections could not be
      # handed to waiters. `@opening` reserves the position; the open runs
      # outside, then the connection joins `@conns` and the waiters are woken.
      def lease
        idx = -1
        opening = false
        replacement = false
        @lock.synchronize do
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @timeout_seconds
          while idx < 0 && !opening
            if !@free.empty?
              idx = @free.delete_at(@free.length - 1)
            elsif !@vacant.empty?
              idx = @vacant.delete_at(@vacant.length - 1)
              @opening += 1
              opening = true
              replacement = true
            elsif @conns.length + @opening < @size
              @opening += 1
              opening = true
            else
              remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
              if remaining <= 0
                raise Sqlx::ConnectionTimeout, "Sqlx::Database: no pooled PostgreSQL connection within " + @timeout_seconds.to_s + "s"
              end
              @cv.wait(@lock, remaining)
            end
          end
        end
        if opening
          begin
            conn = PgConnection.new(@conninfo)
            @lock.synchronize do
              if replacement
                conn.attach_to_position(idx)
                @conns[idx] = conn
              else
                idx = @conns.length
                conn.attach_to_position(idx)
                @conns.push(conn)
              end
              @opening -= 1
              @cv.signal
            end
          rescue
            @lock.synchronize do
              @vacant.push(idx) if replacement
              @opening -= 1
              @cv.signal
            end
            raise
          end
        end
        idx
      end

      # Parse a millisecond env value into seconds. An unset or empty value
      # takes the default; anything that is not a non-negative integer is a
      # configuration error, not a silent disable.
      def env_seconds(name, default_ms)
        value = ENV[name]
        return default_ms / 1000.0 if value.nil? || value == ""

        ms = value.to_i
        if ms < 0 || ms.to_s != value
          raise ArgumentError, "Sqlx::Database: " + name + " must be a non-negative integer of milliseconds, got " + value.inspect
        end
        ms / 1000.0
      end

      private :lease, :env_seconds
    end

    # The stored-time codec lives in ext (`String#to_time`, `Time#to_fs(:db)`),
    # reached off the requires every persistence-touching bootstrap (main.rb AND
    # the emitted test_helper) already loads.
    @pool = nil
    # Parity with the sqlite sibling's surface (there it serialises prepare's
    # shared out-buffer; there is no out-buffer here).
    @prepare_lock = Mutex.new
    @query_log = nil
    @sql_trace = false

    # `configure(conninfo, pool_size: 8)` — build this adapter's connection pool
    # and validate that the server is reachable. `DATABASE_POOL_SIZE` overrides
    # `pool_size` when set, matching the sqlite sibling. The probe connection
    # opens and closes before the pool goes lazy: a bad conninfo stops boot, and
    # a prefork child never inherits the parent's socket.
    #
    # @param conninfo [String] a libpq conninfo string (`PG_URL`), not a file
    #   path — the sqlite parameter name survives so both adapters share one
    #   signature
    # @param pool_size [Integer] requested connection count; `DATABASE_POOL_SIZE`
    #   overrides it when set
    # @return [void]
    # @raise [Sqlx::ConnectionFailed] the server refuses the connection (the
    #   message carries the driver's own error text)
    def self.configure(conninfo, pool_size: 8)
      @sql_trace = ENV.fetch("RH_SQL_TRACE", "") != ""
      n = pool_size
      ev = ENV["DATABASE_POOL_SIZE"]
      if !ev.nil? && ev != ""
        n = ev.to_i
      end
      probe = PgConnection.new(conninfo)
      probe.close
      close unless @pool.nil?
      @pool = PgPool.new(conninfo, n)
      # A reconnect replaces the database behind any cached rows; invalidate
      # every request's cache before the new connection serves a read.
      query_cache_clear
    end

    # `configure_default!()` — configure from this adapter's own source:
    # `PG_URL`, a libpq conninfo string, required. `main.rb` never names an
    # adapter; it calls this.
    #
    # @return [void]
    # @raise [RuntimeError] `PG_URL` is missing or empty
    # @raise [Sqlx::ConnectionFailed] the server refuses the connection
    def self.configure_default!
      conninfo = ENV["PG_URL"]
      if conninfo.nil? || conninfo.empty?
        raise "PG_URL is required - this adapter speaks PostgreSQL (schema owned by the application)"
      end
      configure(conninfo)
    end

    def self.close
      if !@pool.nil?
        @pool.close_all
        @pool = nil
      end
      # Cached rows belong to the connections that produced them.
      query_cache_clear
    end

    # `exec(sql)` — run one DDL / INSERT / UPDATE / DELETE statement; no rows
    # come back. Callers that want the inserted id or the row count read
    # `last_insert_rowid` / `changes` next.
    #
    # @param sql [String] the statement, with values inlined — this entry binds
    #   nothing
    # @return [void]
    # @raise [Sqlx::RecordNotUnique] a UNIQUE constraint rejects the statement
    # @raise [Sqlx::Busy] the lock wait failed (deadlock, lock timeout, or a
    #   serialization failure); the statement did not commit
    # @raise [Sqlx::ConnectionFailed] the session died; the statement's outcome
    #   is unknown — retry the unit, not the statement
    def self.exec(sql)
      current_conn
      record_query(sql)
      started = Snails::Logger::Context.now_us
      begin
        res = pq_exec(autoincrement_shim(sql))
        Libpq.PQclear(res)
      ensure
        query_cache_clear
        Snails::Logger::Context.add_db_us(Snails::Logger::Context.now_us - started)
      end
    end

    # `exec_read(sql, values)` — run one statement with the caller's
    # values bound and hand back the rows it produced, keyed by column
    # name. The binding is this adapter's (the same one `exec_write`
    # uses); a caller that wants the rows of a statement with values
    # comes here.
    #
    # Inside a `with_connection` scope, an identical SELECT replays the
    # first result. The cache key is the statement as executed — bind
    # values substituted — so bound reads are cached too (the sqlite
    # sibling keys on SQL text alone and skips `?`-bearing reads). A write
    # or DDL empties the cache; outside a scope every call round-trips.
    #
    # @param sql [String] the statement to run, with a `?` for each value
    # @param values [Array, nil] one value per `?` — nil for a statement
    #   that takes none. nil binds NULL, a Time binds in the runtime's
    #   stored form (UTC), everything else by its runtime type
    # @return [Array] one name-keyed row per row the statement produced —
    #   an empty array when it produced none
    # @raise [Sqlx::Busy] the lock wait failed; the statement did not run
    # @raise [Sqlx::ConnectionFailed] the session died; the statement's outcome
    #   is unknown — retry the unit, not the statement
    # @example
    #   Sqlx::Database.exec_read("SELECT id FROM t WHERE a = ?", [ "x" ])
    #   # => [ { "id" => 7 } ]
    def self.exec_read(sql, values)
      current_conn
      bound = values.nil? ? [] : values
      final = final_sql_for(sql, bound)
      cacheable = select_read?(sql)
      generation = @query_cache_generation
      if cacheable
        cached = query_cache_fetch(final, generation)
        unless cached.nil?
          record_cache_hit(sql)
          return cached
        end
      end
      record_query(sql)
      started = Snails::Logger::Context.now_us
      begin
        stmt = PgStmt.new(final)
        rows = read_rows(stmt)
        finalize(stmt)
        query_cache_store(final, rows, generation) if cacheable
        rows
      ensure
        Snails::Logger::Context.add_db_us(Snails::Logger::Context.now_us - started)
      end
    end

    # `exec_write(sql, values)` — run one statement with the caller's
    # values bound and hand back what that execution produced: the rows
    # it returned and the rows it changed.
    #
    # The two answers belong to one execution — the count is final only
    # once the statement is done, and a statement that returns rows is
    # done after its last row is stepped — so one call carries both and
    # the caller reads the one it needs. The write invalidates the request
    # read cache before it returns, so a later identical SELECT sees the
    # new rows.
    #
    # @param sql [String] the statement to run, with `?` placeholders
    # @param values [Array] one value per `?` — nil binds NULL, a Time
    #   binds in the runtime's stored form (UTC, whatever zone the
    #   caller handed over), everything else binds by its runtime type
    # @return [Hash] the execution's result, with two keys — "rows"
    #   holds one name-keyed row per row the statement RETURNED (an
    #   empty array when it returned none) and "count" holds the number
    #   of rows the statement CHANGED. The count is defined for
    #   row-changing statements (INSERT/UPDATE/DELETE): a statement
    #   that changes no rows reports 0, and a statement that returns
    #   rows reports the rows it returned (one per changed row), so
    #   count and row count agree. A statement that changes nothing and
    #   returns nothing (DDL) reports the driver's own last-change
    #   value, which is not a row count — DDL is not this entry's
    #   question.
    # @raise [Sqlx::RecordNotUnique] a UNIQUE constraint rejects the
    #   statement
    # @raise [Sqlx::Busy] the lock wait failed; the statement did not commit
    #   and may be retried as part of its unit
    # @raise [Sqlx::ConnectionFailed] the session died; the statement's outcome
    #   is unknown — retry the unit, not the statement
    # @example
    #   Sqlx::Database.exec_write("INSERT INTO t (a) VALUES (?)", [ "x" ])
    #   # => { "rows" => [], "count" => 1 }
    #   Sqlx::Database.exec_write("UPDATE t SET a = ? WHERE id = ? RETURNING id", [ "x", 7 ])
    #   # => { "rows" => [ { "id" => 7 } ], "count" => 1 }
    def self.exec_write(sql, values)
      current_conn
      started = Snails::Logger::Context.now_us
      begin
        stmt = prepare(sql)
        i = 0
        while i < values.length
          bind_value(stmt, i + 1, values[i])
          i += 1
        end
        rows = read_rows(stmt)
        status = Libpq.PQresultStatus(stmt.res)
        count = 0
        if status == Libpq::PGRES_COMMAND_OK
          tuples = Libpq.PQcmdTuples(stmt.res)
          count = tuples.nil? || tuples == "" ? 0 : tuples.to_i
        else
          count = rows.length
        end
        finalize(stmt)
        { "rows" => rows, "count" => count }
      ensure
        query_cache_clear
        Snails::Logger::Context.add_db_us(Snails::Logger::Context.now_us - started)
      end
    end

    # Adapter hook for the shared lease engine (`database/lease.rb`): check out
    # one pooled connection with its health proof. nil before `configure` — the
    # first database access inside a scope then fails on the absent pool.
    def self.lease_checkout
      pool = @pool
      return nil if pool.nil?

      pool.checkout
    end

    # `last_insert_rowid()` — the id the last INSERT in this session produced. PG
    # identity columns advance a sequence rather than a rowid, so this reads
    # `lastval()`: the session's last `nextval()`, the per-connection answer this
    # adapter keeps. A session that has inserted nothing raises from PG; that
    # reads back as 0, sqlite's answer too.
    #
    # @return [Integer] the session's last sequence value, 0 before any INSERT
    # @raise [Sqlx::ConnectionFailed] the lease's connection is gone
    def self.last_insert_rowid
      v = query_int("SELECT lastval()")
      v.nil? ? 0 : v
    end

    # `changes()` — the row count of the last non-RETURNING
    # INSERT/UPDATE/DELETE on this lease's connection. A statement with
    # RETURNING reports its count through `exec_write`, not here; this
    # accessor keeps the previous count. SQLite's sqlite3_changes does
    # update for RETURNING — core never reads it after a RETURNING write.
    #
    # @return [Integer] the affected-row count of the last row-changing
    #   statement without RETURNING
    # @raise [Sqlx::ConnectionFailed] the lease's connection is gone
    def self.changes
      current_conn.changes
    end

    # `owns_schema?()` — whether this adapter owns its schema DDL. It answers
    # false here: the schema belongs to the application's deployment, so this
    # process applies no DDL (the sqlite sibling answers true). An explicit
    # loader reads this flag; the server never runs DDL either way.
    #
    # @return [Boolean] false for PostgreSQL
    def self.owns_schema?
      false
    end

    # `adapter_name()` — the dialect name apps branch on; each adapter answers
    # its own.
    #
    # @return [String] this adapter's dialect name, "PostgreSQL"
    def self.adapter_name
      "PostgreSQL"
    end

    # `quote(value)` — the adapter's SQL literal renderer: NULL, a bare number,
    # the adapter's boolean spelling, the stored Time form, else a quoted string.
    # The escape helpers are the implementation; callers go through `Sqlx.quote`.
    #
    # @return [String] the SQL literal for `value`
    def self.quote(value)
      if value.nil?
        "NULL"
      elsif value.is_a?(Integer) || value.is_a?(Float)
        value.to_s
      elsif value.is_a?(TrueClass) || value.is_a?(FalseClass)
        escape_bool(value)
      elsif value.is_a?(Time)
        escape_string(value.to_fs(:db))
      else
        escape_string(value.to_s)
      end
    end

    def self.sql_trace?
      @sql_trace
    end

    # Implementation helpers — private on purpose. The public entries above are
    # the adapter contract; the `private_class_method` list at the bottom is the
    # boundary.

    # A fresh statement object; no server round trip yet. See PgStmt.
    def self.prepare(sql)
      record_query(sql)
      PgStmt.new(sql)
    end

    # Runs the statement at first use, then advances the row cursor. `sql` is
    # accepted for interface parity with the sqlite adapter, where it enriches the
    # step-error message; here `ensure_executed` reports its own.
    def self.step?(stmt, sql = nil)
      ensure_executed(stmt)
      n = Libpq.PQntuples(stmt.res)
      if stmt.row + 1 < n
        stmt.row = stmt.row + 1
        true
      else
        false
      end
    end

    def self.column_int(stmt, i)
      ensure_executed(stmt)
      return 0 if stmt.row < 0
      return 0 if Libpq.PQgetisnull(stmt.res, stmt.row, i) == 1

      oid = Libpq.PQftype(stmt.res, i)
      if oid == Libpq::BOOLOID
        return cell_is_true(stmt, i) ? 1 : 0
      end
      # `sqlite3_column_int` parses a leading integer (atoi semantics);
      # `String#to_i` matches it, including 0 for a non-numeric head.
      cell_text(stmt, i).to_i
    end

    def self.column_float(stmt, i)
      ensure_executed(stmt)
      return 0.0 if stmt.row < 0
      return 0.0 if Libpq.PQgetisnull(stmt.res, stmt.row, i) == 1

      oid = Libpq.PQftype(stmt.res, i)
      if oid == Libpq::BOOLOID
        return cell_is_true(stmt, i) ? 1.0 : 0.0
      end
      cell_text(stmt, i).to_f
    end

    # sqlite's `column_text` answers "" for NULL — same shape here, so a hydrating
    # reader cannot tell the adapters apart.
    def self.column_text(stmt, i)
      ensure_executed(stmt)
      return "" if stmt.row < 0
      return "" if Libpq.PQgetisnull(stmt.res, stmt.row, i) == 1

      oid = Libpq.PQftype(stmt.res, i)
      if oid == Libpq::BOOLOID
        # sqlite stores booleans as 0/1 integers, so its text read of a
        # boolean column is "1"/"0"; PG renders 't'/'f'. Map them back.
        return cell_is_true(stmt, i) ? "1" : "0"
      end
      cell_text(stmt, i)
    end

    # Nullable reads: NULL stays nil rather than collapsing to "" / 0.
    def self.column_int_opt(stmt, i)
      ensure_executed(stmt)
      return nil if stmt.row < 0
      return nil if Libpq.PQgetisnull(stmt.res, stmt.row, i) == 1

      column_int(stmt, i)
    end

    def self.column_float_opt(stmt, i)
      ensure_executed(stmt)
      return nil if stmt.row < 0
      return nil if Libpq.PQgetisnull(stmt.res, stmt.row, i) == 1

      column_float(stmt, i)
    end

    def self.column_text_opt(stmt, i)
      ensure_executed(stmt)
      return nil if stmt.row < 0
      return nil if Libpq.PQgetisnull(stmt.res, stmt.row, i) == 1

      column_text(stmt, i)
    end

    # A datetime column: the stored UTC text read back as a Time; nil (or text
    # too short to carry an instant) reads nil.
    def self.column_time(stmt, i)
      text = column_text(stmt, i)
      text.nil? ? nil : text.to_time
    end

    def self.column_time_opt(stmt, i)
      text = column_text_opt(stmt, i)
      text.nil? ? nil : text.to_time
    end

    def self.column_bool_opt(stmt, i)
      ensure_executed(stmt)
      return nil if stmt.row < 0
      return nil if Libpq.PQgetisnull(stmt.res, stmt.row, i) == 1

      column_int(stmt, i) != 0
    end

    # Column count/name answer before the first step — `read_rows` reads them to
    # size the row Hash it is about to fill.
    def self.column_count(stmt)
      ensure_executed(stmt)
      stmt.ncols
    end

    def self.column_name(stmt, i)
      ensure_executed(stmt)
      s = Libpq.PQfname(stmt.res, i)
      s.nil? ? "" : s
    end

    # Release the statement's PGresult. Unlike the sqlite sibling's cached-stmt
    # finalize (a reset), this really frees: every emit path treats finalize as
    # terminal for its handle, and a second prepare builds a new object anyway.
    def self.finalize(stmt)
      if !stmt.res.nil?
        Libpq.PQclear(stmt.res)
        stmt.res = nil
      end
      stmt.row = -1
      stmt.dead = true
    end

    # Placeholder binding: render the value for the 1-based `?` slot into its SQL
    # text NOW and store the text. The params array only ever holds Strings —
    # storing raw hetero values trips the AOT's one-type-per-array rule (a write
    # binds ints, texts, times and nil side by side). Substitution splices the
    # stored text verbatim, so a bind after prepare still reaches the server.
    # `pending` is an untyped attr_accessor; spinel AOT accepts only a bool
    # condition, so compare explicitly.
    def self.bind_int(stmt, idx, value)
      return nil unless stmt.pending == true

      stmt.params[idx - 1] = render_param(value.to_i)
    end

    def self.bind_text(stmt, idx, value)
      return nil unless stmt.pending == true

      stmt.params[idx - 1] = render_param(value.to_s)
    end

    def self.bind_bool(stmt, idx, value)
      return nil unless stmt.pending == true

      stmt.params[idx - 1] = render_param(value ? true : false)
    end

    # Same escaping shape as the sqlite sibling: single-quote doubling matches
    # PostgreSQL's literal-string syntax too (and the default
    # standard_conforming_strings=on keeps backslashes literal, as sqlite does), so
    # a value cannot tell the adapters apart.
    def self.escape_string(s)
      "'" + s.to_s.gsub("'", "''") + "'"
    end

    def self.escape_int(n)
      n.to_i.to_s
    end

    def self.escape_int_opt(n)
      n.nil? ? "NULL" : escape_int(n)
    end

    # A datetime value as a SQL literal: the adapter's stored form
    # (`Time#to_fs(:db)`), quoted.
    def self.escape_time(value)
      escape_string(value.is_a?(Time) ? value.to_fs(:db) : value)
    end

    def self.escape_time_opt(value)
      escape_string_opt(value.is_a?(Time) ? value.to_fs(:db) : value)
    end

    def self.escape_float_opt(f)
      f.nil? ? "NULL" : f.to_f.to_s
    end

    def self.escape_bool_opt(b)
      b.nil? ? "NULL" : escape_bool(b)
    end

    # Empty list → "NULL" so `IN (NULL)` is valid SQL matching no rows.
    def self.escape_int_list(ids)
      return "NULL" if ids.empty?

      ids.map { |i| i.to_i.to_s }.join(", ")
    end

    # '1'/'0' as a QUOTED unknown-type literal: PostgreSQL coerces it to boolean
    # for a boolean column ('1'::boolean) and to integer for an integer column
    # ('1'::int), so one spelling serves every emitted site — sqlite's bare 1/0
    # would fail on the boolean column.
    def self.escape_bool(b)
      b ? "'1'" : "'0'"
    end

    # Read a boolean column: PG renders 't'/'f', widen to bool.
    def self.column_bool(stmt, idx)
      column_int(stmt, idx) != 0
    end

    # `final_sql_for(sql, values)` — the statement as it goes to the server: each
    # unquoted `?` replaced by its rendered value. The same text is the cache key,
    # so bound reads are cached by value rather than skipped.
    #
    # @return [String]
    def self.final_sql_for(sql, values)
      return sql if values.empty?
      rendered = []
      i = 0
      while i < values.length
        rendered.push(render_param(values[i]))
        i += 1
      end
      substitute_params(sql, rendered)
    end

    # Parity with the sqlite sibling: a mutex call sites may ask for.
    def self.prepare_lock
      @prepare_lock
    end

    # Page-level seeding is a sqlite backup concept; the PG adapter takes its
    # schema and data from the application's deployment. Loud beats a silent no-op.
    def self.seed_from_file(src_path)
      raise "Sqlx::Database.seed_from_file: unsupported in the PG adapter — schema and data belong to the application"
    end

    # ── internals ─────────────────────────────────────────────────────

    # Raw cell text and the boolean read, shared by the column readers. PG renders
    # booleans as 't'/'f' only.
    def self.cell_text(stmt, i)
      Libpq.PQgetvalue(stmt.res, stmt.row, i)
    end

    # Internal helpers — private on purpose: the primitive surface documented
    # at the top of this file is the contract; these are free to change
    # without notice.

    # Render one raw value into its `?` slot — pre-rendered to text for the same
    # one-type rule as above. nil renders NULL, a Time the stored form; dispatch
    # lives in `render_param`.
    def self.bind_value(stmt, idx, v)
      return nil unless stmt.pending == true

      stmt.params[idx - 1] = render_param(v)
    end

    # The connection every caller reads through. Inside a `with_connection`
    # scope the first database access checks one out of the pool; a scope with
    # no database access never checks one out. Outside a scope, single-fiber
    # contexts before `require_leases!` fall back to the pool's first
    # connection. After `require_leases!` there is no fallback — an access
    # outside a scope raises instead of sharing a connection another thread may
    # hold mid-transaction.
    def self.current_conn
      c = ensure_connection
      return c if !c.nil?
      if @lease_required
        raise "Sqlx::Database: no connection lease on this thread — wrap the call in Sqlx::Database.with_connection"
      end
      if @pool.nil?
        raise "Sqlx::Database: not configured (PG_URL missing?)"
      end
      @pool.first
    end

    # Funnel hook: one SQL string into the active capture, if any.
    def self.record_query(sql)
      @query_log.push(sql) unless @query_log.nil?
      if @sql_trace
        $stderr.puts "  SQL " + sql
      end
    end

    # Query-log capture — the test-side SQL-string log, as in the sqlite sibling.
    def self.capture_sql
      prev = @query_log
      log = []
      @query_log = log
      begin
        yield
      ensure
        @query_log = prev
      end
      log
    end

    # Raw typed column read — the same contract the sqlite sibling answers:
    # Integer, Float, String, nil for NULL, dispatched on the column's OID (this
    # adapter's analog of sqlite's storage-class probe).
    def self.column_value(stmt, i)
      ensure_executed(stmt)
      return nil if stmt.row < 0
      return nil if Libpq.PQgetisnull(stmt.res, stmt.row, i) == 1

      oid = Libpq.PQftype(stmt.res, i)
      if oid == Libpq::BOOLOID
        # sqlite's INTEGER storage class: a boolean reads back as 1/0.
        return cell_is_true(stmt, i) ? 1 : 0
      end
      if oid == Libpq::INT2OID || oid == Libpq::INT4OID || oid == Libpq::INT8OID || oid == Libpq::OIDOID
        return cell_text(stmt, i).to_i
      end
      if oid == Libpq::FLOAT4OID || oid == Libpq::FLOAT8OID
        return cell_text(stmt, i).to_f
      end
      if oid == Libpq::NUMERICOID
        # sqlite's NUMERIC affinity stores 42 as INTEGER and 42.5 as
        # REAL; PG renders scale-0 numerics without a decimal point, so
        # the dot decides Integer vs Float the same way.
        t = cell_text(stmt, i)
        if t.include?(".") || t.include?("e") || t.include?("E")
          return t.to_f
        end
        return t.to_i
      end
      # text / varchar / timestamp / date / json — sqlite hands these
      # back as TEXT strings, and so do we.
      cell_text(stmt, i)
    end

    def self.escape_string_opt(s)
      s.nil? ? "NULL" : escape_string(s)
    end

    # A query-cache replay pointer has no meaning here (no cache in this adapter);
    # nil keeps the sqlite-shaped `if stmt.is_a?(Integer)` readers from ever being
    # needed.
    def self.replay_ptr(stmt)
      nil
    end

    def self.dbh
      current_conn.dbh
    end

    # Execute at first use. Params are substituted only when binds actually
    # landed; with none the SQL goes through byte-for-byte, so a literal `?` inside
    # a string in the query cannot be rewritten.
    def self.ensure_executed(stmt)
      if stmt.dead
        raise "Sqlx::Database: statement used after finalize"
      end
      # Same explicit bool comparison as the bind_* helpers: `pending` is an
      # untyped attr_accessor.
      return unless stmt.pending == true

      sql = stmt.sql
      if !stmt.params.empty?
        sql = substitute_params(sql, stmt.params)
      end
      res = pq_exec(sql)
      stmt.res = res
      stmt.pending = false
      stmt.row = -1
      stmt.ncols = Libpq.PQnfields(res)
    end

    # Run one SQL string on the lease's connection. Returns the caller-owned
    # PGresult (raises on a fatal status). A connection-level failure discards
    # the connection before raising `Sqlx::ConnectionFailed`; a later checkout
    # that finds no free connection opens a replacement. Updates the
    # connection's change count only for a COMMAND_OK with a row count.
    # TUPLES_OK results (SELECT, and DML with RETURNING) leave the previous
    # count alone: a SELECT's row count is not a changed-row count, and a
    # RETURNING statement reports its count through `exec_write`. DDL (empty
    # cmdTuples) also leaves it alone.
    #
    # @raise [Sqlx::ConnectionFailed] the session died; the statement's outcome
    #   is unknown (it may have committed)
    def self.pq_exec(sql)
      conn = current_conn
      res = Libpq.PQexec(conn.dbh, sql)
      status = Libpq.PQresultStatus(res)
      if status != Libpq::PGRES_COMMAND_OK && status != Libpq::PGRES_TUPLES_OK && status != Libpq::PGRES_EMPTY_QUERY
        # Read both fields before the result is freed; the SQLSTATE decides
        # whether this is contention a caller can retry as a unit.
        state = Libpq.PQresultErrorField(res, Libpq::PG_DIAG_SQLSTATE)
        msg = Libpq.PQresultErrorMessage(res)
        Libpq.PQclear(res)
        if connection_failed?(conn, state, msg)
          discard_connection(conn)
          raise Sqlx::ConnectionFailed, msg
        end
        raise Sqlx::RecordNotUnique, msg if unique_violation?(msg)
        raise Sqlx::Busy, msg if busy_sqlstate?(state)
        raise "Sqlx::Database.exec failed: " + msg + " — sql: " + sql
      end
      if status == Libpq::PGRES_COMMAND_OK
        ct = Libpq.PQcmdTuples(res)
        if !ct.nil? && ct != ""
          conn.changes = ct.to_i
        end
      end
      res
    end

    # One integer cell. A normal statement error (lastval before any insert)
    # answers nil; a failed connection is discarded and raises
    # `Sqlx::ConnectionFailed` because 0 would be a false answer. Deliberately
    # not record_query'd: it is driver plumbing, not app SQL, and the trace
    # would drift from what the app issued. The accessor that uses it
    # (`last_insert_rowid`) is a real round trip on this adapter, so it joins
    # the request's DB time like a statement entry.
    def self.query_int(sql)
      out = nil
      conn = current_conn
      started = Snails::Logger::Context.now_us
      begin
        res = Libpq.PQexec(conn.dbh, sql)
        status = Libpq.PQresultStatus(res)
        if status == Libpq::PGRES_TUPLES_OK && Libpq.PQntuples(res) == 1 && Libpq.PQgetisnull(res, 0, 0) == 0
          out = Libpq.PQgetvalue(res, 0, 0).to_i
        end
        if status != Libpq::PGRES_TUPLES_OK && status != Libpq::PGRES_COMMAND_OK && status != Libpq::PGRES_EMPTY_QUERY
          state = Libpq.PQresultErrorField(res, Libpq::PG_DIAG_SQLSTATE)
          msg = Libpq.PQresultErrorMessage(res)
          Libpq.PQclear(res)
          if connection_failed?(conn, state, msg)
            discard_connection(conn)
            raise Sqlx::ConnectionFailed, msg
          end
        else
          Libpq.PQclear(res)
        end
        out
      ensure
        Snails::Logger::Context.add_db_us(Snails::Logger::Context.now_us - started)
      end
    end

    # Whether a failed result means the session itself is gone. `PQstatus` sees
    # a dropped socket; SQLSTATE class 08 is libpq's connection-exception class,
    # and 57P01/57P02/57P03 are the server's shutdown/startup states. The message
    # checks cover libpq builds that leave the SQLSTATE unset.
    def self.connection_failed?(conn, state, message)
      return true if Libpq.PQstatus(conn.dbh) != Libpq::CONNECTION_OK
      if !state.nil?
        return true if state.start_with?("08")
        return true if state == "57P01" || state == "57P02" || state == "57P03"
      end
      text = message.to_s
      return true if text.include?("server closed the connection unexpectedly")
      return true if text.include?("connection to server was lost")
      return true if text.include?("terminating connection due to administrator command")
      false
    end

    # Drop a failed connection from the pool. The current lease's release
    # becomes a no-op; a later checkout that finds no free connection refills
    # the position.
    def self.discard_connection(conn)
      pool = @pool
      pool.discard(conn) unless pool.nil?
    end

    # The one sqlite-ism the lowerer emits that PG cannot parse: the AUTOINCREMENT
    # bookkeeping delete inside `_adapter_truncate` (`DELETE FROM sqlite_sequence
    # WHERE name = '…'`). Its job is to restart ids after a truncate; the PG
    # spelling of that intent resets the identity sequence. Only `exec` rewrites,
    # so prepare paths (real queries) are never touched.
    def self.autoincrement_shim(sql)
      prefix = "DELETE FROM sqlite_sequence WHERE name = '"
      m = sql.index(prefix)
      return sql if m.nil?

      start = m + prefix.length
      j = start
      while j < sql.length
        break if sql[j, 1] == "'"

        j = j + 1
      end
      table = sql[start, j - start]
      "ALTER SEQUENCE \"" + table + "_id_seq\" RESTART WITH 1"
    end

    # Replace each unquoted `?` with its bound value, rendered inline.
    # Single-quoted regions are walked over: a `?` inside a literal (the value of
    # an earlier bind, say) is data, not a placeholder.
    def self.substitute_params(sql, params)
      out = ""
      i = 0
      p = 0
      in_str = false
      while i < sql.length
        c = sql[i, 1]
        if in_str
          out = out + c
          if c == "'"
            if sql[i + 1, 1] == "'"
              out = out + "'"
              i = i + 1
            else
              in_str = false
            end
          end
        elsif c == "'"
          in_str = true
          out = out + c
        elsif c == "?"
          if p >= params.length
            raise "Sqlx::Database: ? placeholder " + (p + 1).to_s + " has no bound value"
          end
          out = out + params[p].to_s
          p = p + 1
        else
          out = out + c
        end
        i = i + 1
      end
      out
    end

    def self.render_param(v)
      if v.nil?
        "NULL"
      elsif v.is_a?(Integer)
        v.to_i.to_s
      elsif v == true || v == false
        escape_bool(v)
      elsif v.is_a?(Float)
        v.to_f.to_s
      elsif v.is_a?(Time)
        escape_time(v)
      else
        escape_string(v)
      end
    end

    def self.cell_is_true(stmt, i)
      cell_text(stmt, i) == "t"
    end

    # A UNIQUE-index violation maps to `Sqlx::RecordNotUnique` — the same contract
    # the sqlite sibling maps, with PG's own message added so one rule covers both
    # drivers (app rescues match on the class).
    def self.unique_violation?(message)
      message.include?("UNIQUE constraint failed") ||
        message.include?("duplicate key value violates unique constraint")
    end

    # `busy_sqlstate?(state)` — whether a SQLSTATE means lock contention rather
    # than a broken statement. They share one contract with sqlite's
    # SQLITE_BUSY/LOCKED: the unit did not commit and may be retried as a unit
    # (`Sqlx::Busy`).
    #
    # @param state [String, nil] the result's five-character SQLSTATE
    # @return [Boolean] true for deadlock, lock-not-available and serialization
    #   failures
    def self.busy_sqlstate?(state)
      state == "40P01" || state == "55P03" || state == "40001"
    end

    # Walk an executed statement into name-keyed rows — the one row-shape walk
    # `exec_write` and `exec_read` share. `ensure_executed` runs on the first count
    # read, so a caller binds first and walks here.
    def self.read_rows(stmt)
      ensure_executed(stmt)
      ncols = column_count(stmt)
      names = []
      i = 0
      while i < ncols
        names.push(column_name(stmt, i))
        i += 1
      end
      rows = []
      while step?(stmt)
        row = {}
        i = 0
        while i < ncols
          row[names[i]] = column_value(stmt, i)
          i += 1
        end
        rows.push(row)
      end
      rows
    end
    # The public surface is the high-level list in the sqlite sibling's header.
    # These names are implementation details — cursor, column/bind readers,
    # escape helpers, cache, and connection internals — and are private on
    # purpose.
    private_class_method :read_rows, :current_conn, :dbh, :unique_violation?
    private_class_method :lease_checkout
    private_class_method :busy_sqlstate?
    private_class_method :prepare, :step?, :finalize
    private_class_method :bind_int, :bind_text, :bind_bool, :bind_value
    private_class_method :column_int, :column_float, :column_text, :column_count
    private_class_method :column_name, :column_int_opt, :column_float_opt
    private_class_method :column_text_opt, :column_time, :column_time_opt
    private_class_method :column_bool_opt, :column_bool, :column_value
    private_class_method :cell_text, :cell_is_true
    private_class_method :escape_string, :escape_string_opt, :escape_int
    private_class_method :escape_int_opt, :escape_time, :escape_time_opt
    private_class_method :escape_float_opt, :escape_bool, :escape_bool_opt
    private_class_method :escape_int_list
    private_class_method :capture_sql, :record_query, :replay_ptr
    private_class_method :ensure_executed, :pq_exec, :query_int
    private_class_method :connection_failed?, :discard_connection
    private_class_method :autoincrement_shim, :substitute_params, :render_param
    private_class_method :seed_from_file
    private_class_method :final_sql_for
    private_class_method :prepare_lock
  end
end
