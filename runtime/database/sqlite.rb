# Primitive Sqlx::Database surface — the layer per-model adapter code sits on.
# The contract is database-agnostic and documented here for every backend;
# this file is the SQLite-via-libsqlite3-FFI implementation. The app-owned
# config/database.rb requires this file or its PostgreSQL sibling, so the
# static graph reaches exactly one backend and the vendored runtime/ is
# identical across adapters.
#
# API (the contract every Sqlx::Database shim must satisfy):
#
#   Sqlx::Database.configure(path)          — open a database (":memory:" for tests)
#   Sqlx::Database.configure_default!       — configure from the adapter's env
#   Sqlx::Database.close                    — close the database
#   Sqlx::Database.exec(sql)                — run DDL / INSERT / UPDATE / DELETE
#   Sqlx::Database.exec_read(sql, values)   — run a SELECT, return name-keyed rows
#   Sqlx::Database.exec_write(sql, values)  — run a write, return rows + count
#   Sqlx::Database.with_connection { ... }  — request-scoped lease scope (checkout on first access)
#   Sqlx::Database.require_leases!           — require a lease per access
#   Sqlx::Database.last_insert_rowid        — id of the last INSERTed row
#   Sqlx::Database.changes                  — affected-row count of the last write
#   Sqlx::Database.owns_schema?             — whether this adapter owns DDL
#   Sqlx::Database.adapter_name             — the dialect name
#   Sqlx::Database.quote(value)             — SQL literal for `Sqlx.quote`
#   Sqlx::Database.sql_trace?               — whether SQL tracing is on
#
# Every statement entry (`exec`, `exec_read`, `exec_write`) accumulates its
# elapsed time into `Snails::Logger::Context` (`add_db_us`); that is what the
# request record reports as `snails.db_ms`. A backend that omits the call
# reports zero, so a new backend must follow this part of the contract.
#
# Everything else — the cursor (`prepare`/`step?`/`finalize`), column and
# bind readers, escape helpers, query cache, and connection internals — is
# private: it is this adapter's implementation, not a caller surface.
#
# The per-request read cache is shared with the PostgreSQL sibling — one
# store in `runtime/database/query_cache.rb`. Each adapter owns the cache
# KEY: this one renders the statement and its bind values in the adapter's
# literal form, so a bound read is cached per value rather than skipped.
# Both open the cache when the first database access checks a connection out
# inside a `with_connection` scope, invalidate it on any write or DDL, and
# drop it when the outermost scope ends.
#
# `exec_write` binds each value through the adapter's type dispatch;
# `exec_read` returns name-keyed rows and is the read entry used by
# `Sqlx::Base` and the schema loader. The app never inlines values into
# SQL text; `Sqlx.quote` is the literal renderer for the rare inline case.
#
# The lease engine (`with_connection`/`require_leases!`) lives in
# `database/lease.rb` and is shared with the PostgreSQL sibling; this file
# supplies the checkout hook and its connection pool.
#
# Module-level state is `@pools`, N independent DatabasePool shards of M dbh
# pointers each (`configure` says why it is sharded). The shards are built by
# `configure` but open their connections on first use, so a prefork parent
# that only configures hands no live handle to its children. The prefork
# contract is therefore: configure before fork, and do not touch the database
# in the parent. `current_conn` checks a connection out on first use inside a
# `with_connection` scope and falls back to the pool's first connection
# outside a scope until `require_leases!` (called when the server starts)
# makes every access hold a scope — then it fails instead.

require_relative "lease"

# This file defines `Sqlx::Database`; `runtime/sqlx` owns the rest of it.
module Sqlx
  module Database
    # Bare-metal SQLite3 FFI bindings. Only the surface area the
    # lowerer-emitted `_adapter_*` methods need.
    module SQLite3
      ffi_lib "sqlite3"

      ffi_const :OK,   0
      ffi_const :BUSY, 5
      ffi_const :LOCKED, 6
      ffi_const :ROW,  100
      ffi_const :DONE, 101
      # sqlite3_column_type storage classes. `column_value` reads the driver's
      # native type by storage class, and NULL stays nil.
      ffi_const :INTEGER_TYPE, 1
      ffi_const :FLOAT_TYPE, 2
      ffi_const :TEXT_TYPE, 3
      ffi_const :BLOB_TYPE, 4
      ffi_const :NULL_TYPE, 5
      # open_v2 flags: READWRITE | CREATE | URI. The first two are what plain
      # `sqlite3_open` uses, so a non-URI path opens identically either way.
      ffi_const :OPEN_URI_RWC, 70

      ffi_func :sqlite3_open,              [:str, :ptr],                          :int
      # `sqlite3_open` honors a `file:` URI only on a build compiled with
      # SQLITE_USE_URI, which is a property of the distro's sqlite rather than
      # of this program. `open_v2` takes the flag explicitly, so a URI path means
      # the same thing on every build — and getting it wrong is quiet: sqlite
      # treats the whole `file:x?mode=memory&cache=shared` string as a FILENAME
      # and creates an empty database on disk.
      ffi_func :sqlite3_open_v2,           [:str, :ptr, :int, :str],              :int
      ffi_func :sqlite3_close,             [:ptr],                                :int
      # Online backup — copies one open database over another at the PAGE level,
      # used to seed an in-memory database from a file. `step(-1)` copies all
      # remaining pages in one call, which is what a boot-time seed wants.
      ffi_func :sqlite3_backup_init,       [:ptr, :str, :ptr, :str],              :ptr
      ffi_func :sqlite3_backup_step,       [:ptr, :int],                          :int
      ffi_func :sqlite3_backup_finish,     [:ptr],                                :int
      ffi_func :sqlite3_exec,              [:ptr, :str, :ptr, :ptr, :ptr],        :int
      # Fair lock waiting. `sqlite3_busy_handler` installs a Ruby callback that
      # replaces the default busy handler behind `PRAGMA busy_timeout` — a
      # back-off ladder that lets a waiter sleep through the short gaps between
      # writers (see `busy_wait`).
      ffi_callback :busy,                  [:ptr, :int],                          :int
      ffi_func :sqlite3_busy_handler,      [:ptr, :busy, :ptr],                   :int
      ffi_func :sqlite3_prepare_v2,        [:ptr, :str, :int, :ptr, :ptr],        :int
      ffi_func :sqlite3_step,              [:ptr],                                :int
      ffi_func :sqlite3_finalize,          [:ptr],                                :int
      # Prepared-statement reuse: `reset` rewinds a stepped stmt so it can be
      # re-stepped, and `clear_bindings` drops any bound params. Cached stmts are
      # reset instead of finalized; `sqlite3_finalize` runs at pool shutdown.
      ffi_func :sqlite3_reset,             [:ptr],                                :int
      ffi_func :sqlite3_clear_bindings,    [:ptr],                                :int
      # Placeholder binding. `bind_int64` binds a `?` param to an integer;
      # `bind_text`'s trailing two args are `nbyte` and the destructor, both -1 —
      # strlen the NUL-terminated text, and `SQLITE_TRANSIENT` so sqlite copies
      # the bytes before returning. The int→:ptr coercion for that -1 destructor
      # is a spinel FFI primitive.
      ffi_func :sqlite3_bind_int64,        [:ptr, :int, :long],                   :int
      ffi_func :sqlite3_bind_text,         [:ptr, :int, :str, :int, :ptr],        :int
      # NULL and REAL binds: nil must bind NULL (not ""), and REAL columns must
      # round-trip without a text detour.
      ffi_func :sqlite3_bind_double,       [:ptr, :int, :double],                 :int
      ffi_func :sqlite3_bind_null,         [:ptr, :int],                         :int
      # `sqlite3_column_type` reports the storage class of a column in the
      # current row. The nullable reads need it because `sqlite3_column_int`
      # cannot distinguish a stored 0 from NULL (both come back as 0).
      ffi_func :sqlite3_column_type,       [:ptr, :int],                          :int
      ffi_func :sqlite3_column_int,        [:ptr, :int],                          :int
      ffi_func :sqlite3_column_double,     [:ptr, :int],                          :double
      ffi_func :sqlite3_column_text,       [:ptr, :int],                          :str
      ffi_func :sqlite3_column_count,      [:ptr],                                :int
      ffi_func :sqlite3_column_name,       [:ptr, :int],                          :str
      ffi_func :sqlite3_errmsg,            [:ptr],                                :str
      ffi_func :sqlite3_last_insert_rowid, [:ptr],                                :long
      ffi_func :sqlite3_changes,           [:ptr],                                :int

      # Out-params: sqlite3_open_v2 writes the db handle here, prepare_v2 the
      # stmt handle. 8 bytes is enough for a 64-bit pointer.
      ffi_buffer :db_out,   8
      ffi_buffer :stmt_out, 8
      # Separate from db_out: the seed source is opened while the pool's handles
      # already exist, and reusing db_out would overwrite a live one.
      ffi_buffer :seed_out, 8
      ffi_read_ptr :read_ptr, 0
    end

    # One cache entry: the composed SQL and its prepared stmt ptr. A concrete
    # class rather than a bare ptr, so an Array of them types concretely and
    # `length`/`[]` resolve.
    class Stmt
      def initialize(sql, ptr)
        @sql = sql
        @ptr = ptr
      end

      def sql
        @sql
      end

      def ptr
        @ptr
      end
    end

    # One pooled connection plus its prepared-statement cache. The cache is
    # per-connection by necessity: a stmt carries its cursor and belongs to the
    # connection that prepared it, so a shared map would let two fibers corrupt
    # each other. The pool leases a connection to one fiber at a time, so the
    # cache needs no mutex.
    #
    # The key is the composed SQL: the static shape (`WHERE id = ?`) when the
    # bind gate is on, per-value when the lowerer inlines literals.
    class DatabaseConnection
      CAP = 128
      # `SQLite3.stmt_out` is ONE 8-byte out-buffer for the whole process (an
      # `ffi_buffer`, static C storage), so two connections preparing at once
      # would read each other's statement pointer and take the process down.
      # The prepare and the read of that buffer are one critical section.
      PREPARE_LOCK = Mutex.new

      def initialize(dbh)
        @dbh = dbh
        @entries = []
      end

      def dbh
        @dbh
      end

      # `prepare_cached(sql)` — the prepared stmt for `sql`, from the cache on a
      # hit and freshly prepared and cached on a miss. The scan is linear: the
      # hit rate matters, not the lookup's constant.
      #
      # EVERY prepared stmt goes into @entries, with no cap check — that is what
      # makes `finalize`'s reset-don't-close correct for all of them, since every
      # stmt handed back stays reachable and finalizable at `trim!`.
      #
      # @param sql [String] the composed SQL to prepare
      # @return [Object] the statement's driver handle
      def prepare_cached(sql)
        i = 0
        while i < @entries.length
          e = @entries[i]
          return e.ptr if e.sql == sql
          i += 1
        end
        # `SQLite3.stmt_out` is ONE 8-byte out-buffer for the whole process (an
        # `ffi_buffer`, static C storage), so two connections preparing at once
        # would read each other's statement pointer and take the process down.
        # The prepare and the read of that buffer are one critical section. No
        # raise inside the lock: `synchronize` has no ensure on this adapter.
        rc = 0
        st = 0
        PREPARE_LOCK.synchronize do
          rc = SQLite3.sqlite3_prepare_v2(@dbh, sql, -1, SQLite3.stmt_out, nil)
          st = rc == SQLite3::OK ? SQLite3.read_ptr(SQLite3.stmt_out) : 0
        end
        if rc != SQLite3::OK
          raise Sqlx::Busy, SQLite3.sqlite3_errmsg(@dbh) if busy_result?(rc)
          raise "Sqlx::Database.prepare failed (" + rc.to_s + "): " + SQLite3.sqlite3_errmsg(@dbh) + " — sql: " + sql
        end
        @entries.push(Stmt.new(sql, st))
        st
      end

      # `trim!()` — bring the statement cache back to `CAP`, finalizing what it
      # drops. Call it at the request boundary (`with_connection`), never
      # mid-request: a stmt an open cursor still holds must not be closed, and
      # between requests there are none.
      #
      # The CAP most-recent entries survive — the tail, since `prepare_cached`
      # appends, and recency is the best available proxy for reuse.
      #
      # @return [void]
      def trim!
        return nil if @entries.length <= CAP
        keep = []
        drop_before = @entries.length - CAP
        i = 0
        while i < @entries.length
          if i < drop_before
            SQLite3.sqlite3_finalize(@entries[i].ptr)
          else
            keep.push(@entries[i])
          end
          i += 1
        end
        @entries = keep
      end

      # `step_real(stmt, sql = nil)` — advance one real statement by one row. The
      # connection owns the driver call so the module's `step?` and the replay
      # path share one implementation.
      #
      # @param sql [String] optional statement text, only to enrich the error
      #   message
      # @return [Boolean] true when a row is ready, false when the statement
      #   finished
      # @raise [Sqlx::RecordNotUnique] a UNIQUE constraint rejects the statement;
      #   any other driver error raises RuntimeError naming the statement
      def step_real(stmt, sql = nil)
        rc = SQLite3.sqlite3_step(stmt)
        if rc == SQLite3::ROW
          return true
        elsif rc == SQLite3::DONE
          return false
        end
        msg = SQLite3.sqlite3_errmsg(@dbh)
        SQLite3.sqlite3_reset(stmt)
        SQLite3.sqlite3_clear_bindings(stmt)
        # The parameterized path is the standard write path, so a UNIQUE
        # violation maps to RecordNotUnique here the same way `exec` maps it.
        raise Sqlx::Busy, msg if busy_result?(rc)
        raise Sqlx::RecordNotUnique, msg if unique_violation?(msg)
        suffix = sql.nil? ? "" : " — sql: " + sql
        raise "Sqlx::Database.step failed (" + rc.to_s + "): " + msg + suffix
      end

      # `unique_violation?(message)` — whether the driver's message reports a
      # UNIQUE-index violation, so the raise sites can map it to
      # `Sqlx::RecordNotUnique` — the class apps write their rescues against,
      # which keeps the raw driver error from reaching the dispatcher as a 500.
      # The test is sqlite's own engine message rather than a driver exception
      # class, so one rule needs no per-driver class table.
      #
      # @param message [String] the driver's error message
      # @return [Boolean] true when the message reports a UNIQUE violation
      def unique_violation?(message)
        message.include?("UNIQUE constraint failed")
      end

      # `busy_result?(rc)` — whether a driver result code means the lock could
      # not be taken: another writer is committing, or a reader holds the file
      # exclusively. Both map to `Sqlx::Busy` at every raise site, so a caller
      # can retry a unit instead of matching the "... is locked" message text.
      #
      # @param rc [Integer] the driver's result code
      # @return [Boolean] true for SQLITE_BUSY and SQLITE_LOCKED
      def busy_result?(rc)
        rc == SQLite3::BUSY || rc == SQLite3::LOCKED
      end

      # `finalize_all()` — really finalize every cached statement, releasing its
      # handle. Pool-shutdown path only.
      #
      # @return [void]
      def finalize_all
        i = 0
        while i < @entries.length
          SQLite3.sqlite3_finalize(@entries[i].ptr)
          i += 1
        end
      end
    end

    # Dedicated SQLite connection pool. A single-use object so its instance ivars
    # type concretely: @conns is a DatabaseConnection PtrArray (objects keep their
    # tag, unlike a generic pool's int slot), @free is an IntArray stack of
    # available indices into @conns.
    class DatabasePool
      # PRAGMAs ARE PER-CONNECTION, so they run on every handle the pool opens,
      # not once on the first; a file-backed server re-reads its working set
      # through the OS page cache on every request otherwise.
      #
      # cache_size is NEGATIVE on purpose: sqlite reads a positive value as a page
      # COUNT and a negative one as a KiB budget, so -65536 is 64 MiB regardless
      # of page_size, while 65536 would be 64k PAGES.
      #
      # An in-memory database ignores these (its pages are already the heap),
      # which is harmless.
      PRAGMAS = [
        "PRAGMA cache_size=-65536",
        # Read pages straight out of the page cache by mapping the file, which
        # drops the read() syscall and its copy for everything that fits.
        "PRAGMA mmap_size=268435456",
        # WAL for readers-alongside-writer. The lock wait is not a pragma: the
        # pool installs a fair busy handler on every connection (see
        # `busy_wait`), because `PRAGMA busy_timeout` sleeps on a back-off ladder
        # that starves waiters under a stream of short writes.
        "PRAGMA journal_mode=WAL",
        # NORMAL, because FULL fsyncs the WAL on EVERY COMMIT. Set rather than
        # left to a library default, so a rebuild cannot move the durability
        # setting silently. NORMAL survives a process crash and risks only the
        # most recent commits on OS or power failure.
        "PRAGMA synchronous=NORMAL",
      ].freeze

      def initialize(path, n)
        @path  = path
        @size  = n
        @conns = []
        @free  = []
        @lock  = Mutex.new
        @cv    = ConditionVariable.new
        # Connections open on first use, not here: a prefork child inherits
        # nothing because the parent never opened a handle before the fork.
        @open_lock = Mutex.new
        @opened    = false
      end

      # `ensure_open()` — open this pool's connections once, on first use. The
      # prefork parent calls `configure` and forks before any database access,
      # so the child inherits an unopened pool object and opens its own
      # handles here. The open lock serializes simultaneous first requests so
      # the pool is not built twice.
      #
      # @return [void]
      def ensure_open
        return if @opened

        failure = nil
        conns = []
        # Raising inside `Mutex#synchronize` would skip its unlock on this
        # adapter, so an open error is recorded and raised after the lock.
        @open_lock.synchronize do
          if !@opened
            i = 0
            while i < @size && failure.nil?
              rc = SQLite3.sqlite3_open_v2(@path, SQLite3.db_out, SQLite3::OPEN_URI_RWC, nil)
              if rc != SQLite3::OK
                # Best-effort error surface — sqlite3_errmsg requires a valid
                # db handle, which we don't have on open failure. The numeric
                # rc + path are the only signals we can raise pre-handle.
                failure = "Sqlx::Database.configure: sqlite3_open(" + @path + ") failed (" + rc.to_s + ")"
              else
                dbh = SQLite3.read_ptr(SQLite3.db_out)
                # Deliberately not raising on a refused pragma. Every one of
                # these is an optimization or a politeness; none changes a
                # query's RESULT, so a build that declines one
                # (journal_mode=WAL on a read-only mount, say) should still
                # serve, slower, rather than fail to boot.
                PRAGMAS.each { |p| SQLite3.sqlite3_exec(dbh, p, nil, nil, nil) }
                # The lock wait is a callback, not a pragma; `busy_wait` says
                # why. A refused install is loud: without a handler SQLite
                # answers BUSY immediately, so the pool would be far less
                # available than configured.
                rc = SQLite3.sqlite3_busy_handler(dbh, Sqlx::Database.method(:busy_wait), nil)
                if rc != SQLite3::OK
                  failure = "Sqlx::Database.configure: sqlite3_busy_handler failed (" + rc.to_s + ")"
                else
                  conns.push(DatabaseConnection.new(dbh))
                end
              end
              i += 1
            end
            if failure.nil?
              @lock.synchronize do
                @conns = conns
                i = 0
                while i < conns.length
                  @free.push(i)
                  i += 1
                end
                @opened = true
                @cv.broadcast
              end
            end
          end
        end

        if !failure.nil?
          i = 0
          while i < conns.length
            SQLite3.sqlite3_close(conns[i].dbh)
            i += 1
          end
          raise failure
        end
      end

      def available
        n = 0
        @lock.synchronize do
          n = @free.length
        end
        n
      end

      # `lease()` — a free connection index (LIFO), parking this thread while the
      # pool is empty; `release` signals it.
      #
      # @return [Integer] the leased index, to hand to `conn` and `release`
      def lease
        ensure_open
        idx = 0
        @lock.synchronize do
          while @free.length == 0
            @cv.wait(@lock)
          end
          idx = @free.delete_at(@free.length - 1)
        end
        idx
      end

      # `release(idx, conn, finished)` — return one connection to the free list
      # and wake a waiter. A completed request trims the connection's statement
      # cache first; the release sits in an `ensure` so a raise while trimming
      # cannot leak the slot.
      #
      # @param idx [Integer] the freed slot
      # @param conn [DatabaseConnection] the connection in that slot
      # @param finished [Boolean] whether the block completed without raising
      # @return [void]
      def release(idx, conn, finished)
        begin
          conn.trim! if finished
        ensure
          @lock.synchronize do
            @free.push(idx)
            @cv.signal
          end
        end
      end

      def conn(idx)
        @conns[idx]
      end

      def first
        ensure_open
        @conns[0]
      end

      # `close_all()` — finalize every cached statement on every connection, then
      # close its handle. A pool that never opened (the prefork parent before
      # the fork) has nothing to close.
      #
      # @return [void]
      def close_all
        i = 0
        while i < @conns.length
          c = @conns[i]
          c.finalize_all
          SQLite3.sqlite3_close(c.dbh)
          i += 1
        end
      end
    end

    # The stored-time codec lives in ext (`String#to_time`, `Time#to_fs(:db)`),
    # reached off Sqlx::Database — the one require every persistence-touching
    # bootstrap (main.rb AND the emitted test_helper) already loads.

    # Own connection pool. A generic pool storing handles in an int-slot array
    # breaks here: a DatabaseConnection pointer flattens to a bare machine word
    # and reads back tagged INT, so a later `.dbh` call (guarded `tag == OBJ`)
    # silently no-ops to NULL. DatabasePool keeps its connections in an
    # instance-ivar array, which spinel types as a concrete DatabaseConnection
    # PtrArray — preserving the object tag.
    @pools = nil
    # How long one lock wait may last, in milliseconds. The per-connection busy
    # handler checks it against wall time on every retry (see `busy_wait`), so a
    # waiter gives up at the timeout instead of after a fixed number of back-off
    # steps.
    @busy_timeout_ms = 5000
    # Query-log capture: nil means not capturing; an Array accumulates the SQL
    # each prepare/exec issues (see `capture_sql`).
    @query_log = nil
    # RH_SQL_TRACE=1 prints every SQL string this process prepares to stderr — a
    # real round trip as `  SQL ...`, a request-cache replay as `  CACHE ...`.
    @sql_trace = false

    # `configure(path, pool_size: 8, busy_timeout_ms: 5000)` — configure the
    # database and build its connection pools: `pool_size` FFI handles to
    # `path`, opened on first use. Nothing is opened here, so a prefork parent
    # may call this before fork; the parent must not touch the database before
    # forking, or the child would inherit the parent's handles.
    #
    # Every connection gets the fair busy handler (`busy_wait`) with the same
    # timeout. `DATABASE_BUSY_TIMEOUT_MS` overrides `busy_timeout_ms` when set.
    #
    # @param path [String] the database file to open (`":memory:"` for tests)
    # @param pool_size [Integer] requested handle count; `DATABASE_POOL_SIZE`
    #   overrides it when set
    # @param busy_timeout_ms [Integer] how long one lock wait may take; 0 keeps
    #   SQLite's immediate `Sqlx::Busy` answer
    # @return [void]
    def self.configure(path, pool_size: 8, busy_timeout_ms: 5000)
      @sql_trace = ENV.fetch("RH_SQL_TRACE", "") != ""
      n = pool_size
      ev = ENV["DATABASE_POOL_SIZE"]
      if !ev.nil? && ev != ""
        n = ev.to_i
      end
      @busy_timeout_ms = busy_timeout_ms
      ev = ENV["DATABASE_BUSY_TIMEOUT_MS"]
      if !ev.nil? && ev != ""
        @busy_timeout_ms = ev.to_i
      end
      # SHARDED, because one pool means one mutex taken twice per request
      # (lease, release), and that lock — not the queries under it — pinned the
      # server to a couple of OS workers. A thread cannot simply keep a
      # connection, since a server can hold thousands of green threads, so the
      # pool is split into independent shards and a thread is assigned one for
      # its life: it blocks only on its own shard's condition variable. The cost
      # is that one shard can be busy while another is idle, so sizing keeps at
      # least 4 handles per shard.
      stripes = n / 4
      stripes = 1 if stripes < 1
      stripes = 8 if stripes > 8
      @pools = []
      per = n / stripes
      per = 1 if per < 1
      i = 0
      while i < stripes
        # The shard holds configuration only; its first request opens the
        # handles. Nothing here may open one before a prefork fork.
        @pools.push(DatabasePool.new(path, per))
        i += 1
      end
      @assign_lock = Mutex.new
      @next_pool = 0
    end

    # `busy_wait(user_data, count)` — the per-connection busy handler: wait one
    # millisecond and retry, and give up when the wait has reached
    # `busy_timeout_ms`.
    #
    # SQLite calls it with `count` 0 on the first busy event of one lock wait and
    # an increasing count after that. The timeout is wall-clock, so a waiter that
    # keeps losing the hand-off still ends within `busy_timeout_ms` — the count
    # is only used to detect a new wait.
    #
    # The fixed interval is the point. The default handler behind `PRAGMA
    # busy_timeout` sleeps on a ladder (1, 2, 5, … 100 ms), so a waiter sleeps
    # through the short gaps between writers and can starve for seconds while the
    # database commits steadily. The same fix is
    # `busy_handler_timeout=` in sqlite3 2.0. Unlike an in-process lock, this
    # also covers writers in other processes.
    #
    # The start time is thread-local, like the connection lease: a threaded
    # server has one lock wait per thread at a time. The fiber server shares
    # `Thread.current` across fibers, so there the timeout can start from another
    # fiber's clock — the same documented limit the request context has.
    #
    # @param user_data [untyped] NULL; the callback signature requires the slot
    # @param count [Integer] the retry number of this wait, 0 on its first event
    # @return [Integer] 1 to retry, 0 to give up (`Sqlx::Busy` follows)
    def self.busy_wait(user_data, count)
      if count == 0 || Thread.current[:db_busy_started_us].nil?
        Thread.current[:db_busy_started_us] = (Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000000.0).to_i
      end
      started = Thread.current[:db_busy_started_us]
      now = (Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000000.0).to_i
      if now - started >= @busy_timeout_ms * 1000
        Thread.current[:db_busy_started_us] = nil
        return 0
      end
      sleep 0.001
      1
    end

    # `configure_default!()` — configure from this adapter's own source, so
    # `main.rb` never names an adapter: `DATABASE_PATH`, else
    # `storage/development.sqlite3`.
    #
    # @return [void]
    def self.configure_default!
      path = ENV["DATABASE_PATH"]
      path = "storage/development.sqlite3" if path.nil? || path.empty?
      configure(path)
    end

    def self.close
      return if @pools.nil?
      i = 0
      while i < @pools.length
        @pools[i].close_all
        i += 1
      end
      @pools = nil
    end

    # `exec(sql)` — run one DDL / INSERT / UPDATE / DELETE statement; no rows
    # come back. Callers that want the inserted id or the row count read
    # `last_insert_rowid` / `changes` immediately after.
    #
    # @param sql [String] the statement, with values inlined — this entry binds
    #   nothing
    # @return [void]
    # @raise [Sqlx::RecordNotUnique] a UNIQUE constraint rejects the statement
    # @raise [Sqlx::Busy] the file's lock stayed held past the busy timeout
    def self.exec(sql)
      conn = current_conn
      record_query(sql)
      started = Snails::Logger::Context.now_us
      begin
        # Any exec is (per the Sqlx::Database contract) DDL or a write — either
        # invalidates the whole request cache.
        query_cache_clear
        h = conn.dbh
        rc = SQLite3.sqlite3_exec(h, sql, nil, nil, nil)
        if rc != SQLite3::OK
          msg = SQLite3.sqlite3_errmsg(h)
          raise Sqlx::Busy, msg if conn.busy_result?(rc)
          raise Sqlx::RecordNotUnique, msg if conn.unique_violation?(msg)
          raise "Sqlx::Database.exec failed (" + rc.to_s + "): " + msg + " — sql: " + sql
        end
      ensure
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
    # first result. The cache key covers the statement and its bind values
    # (`cache_key_for`), so bound reads are cached too — the same contract
    # the PostgreSQL sibling answers. A write or DDL invalidates the
    # cache; outside a scope every call round-trips.
    #
    # @param sql [String] the statement to run, with a `?` for each value
    # @param values [Array, nil] one value per `?` — nil for a statement
    #   that takes none. nil binds NULL, a Time binds in the runtime's
    #   stored form (UTC), everything else by its runtime type
    # @return [Array] one name-keyed row per row the statement produced —
    #   an empty array when it produced none
    # @raise [Sqlx::Busy] the file's lock stayed held past the busy timeout
    # @example
    #   Sqlx::Database.exec_read("SELECT id FROM t WHERE a = ?", [ "x" ])
    #   # => [ { "id" => 7 } ]
    def self.exec_read(sql, values)
      current_conn
      bound = values.nil? ? [] : values
      key = cache_key_for(sql, bound)
      cacheable = select_read?(sql)
      generation = @query_cache_generation
      if cacheable
        cached = query_cache_fetch(key, generation)
        unless cached.nil?
          record_cache_hit(sql)
          return cached
        end
      end
      record_query(sql)
      started = Snails::Logger::Context.now_us
      begin
        stmt = prepare(sql)
        bind_params(stmt, bound)
        rows = read_rows(stmt, sql)
        finalize(stmt)
        query_cache_store(key, rows, generation) if cacheable
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
    # the caller reads the one it needs.
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
    # @raise [Sqlx::Busy] the file's lock stayed held past the busy timeout; the
    #   statement did not commit and may be retried as part of its unit
    # @example
    #   Sqlx::Database.exec_write("INSERT INTO t (a) VALUES (?)", [ "x" ])
    #   # => { "rows" => [], "count" => 1 }
    #   Sqlx::Database.exec_write("UPDATE t SET a = ? WHERE id = ? RETURNING id", [ "x", 7 ])
    #   # => { "rows" => [ { "id" => 7 } ], "count" => 1 }
    def self.exec_write(sql, values)
      conn = current_conn
      record_query(sql)
      started = Snails::Logger::Context.now_us
      begin
        # Writes invalidate the request query cache, the same rule `exec` follows.
        query_cache_clear
        stmt = conn.prepare_cached(sql)
        bind_params(stmt, values)
        rows = read_rows(stmt, sql)
        count = SQLite3.sqlite3_changes(conn.dbh)
        finalize(stmt)
        { "rows" => rows, "count" => count }
      ensure
        Snails::Logger::Context.add_db_us(Snails::Logger::Context.now_us - started)
      end
    end

    # Adapter hook for the shared lease engine (`database/lease.rb`): lease one
    # connection from this thread's pool shard. nil before `configure` — the
    # first database access inside a scope then fails on the absent pool. The
    # token releases through the pool, which trims the statement cache on a
    # completed request.
    def self.lease_checkout
      return nil if @pools.nil?

      pool = pool_for_thread
      LeaseToken.new(pool, pool.lease)
    end

    def self.last_insert_rowid
      SQLite3.sqlite3_last_insert_rowid(current_conn.dbh)
    end

    def self.changes
      SQLite3.sqlite3_changes(current_conn.dbh)
    end

    # `owns_schema?()` — whether this adapter owns its schema DDL. It answers
    # true here; the PostgreSQL sibling answers false (there the schema belongs
    # to the application's deployment). The server never runs DDL either way —
    # an explicit loader (a harness or test setup step) reads this to decide
    # whether to apply the app's schema.
    #
    # @return [Boolean] true for this adapter
    def self.owns_schema?
      true
    end

    # `adapter_name()` — the dialect name apps branch on; each adapter answers
    # its own.
    #
    # @return [String] this adapter's dialect name, "SQLite"
    def self.adapter_name
      "SQLite"
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

    # The shard this thread uses, chosen once and remembered. Round-robin
    # under a lock taken ONCE per thread — the thing being avoided is a lock
    # per request, not a lock ever.
    def self.pool_for_thread
      pi = Thread.current[:db_pool]
      return @pools[pi] if pi != nil
      n = 0
      @assign_lock.synchronize do
        n = @next_pool
        @next_pool = n + 1
      end
      pi = n % @pools.length
      Thread.current[:db_pool] = pi
      @pools[pi]
    end

    # Replace this database's contents with those of the file at `src_path`,
    # page for page, then leave planner statistics behind. An in-memory database is
    # a shape this runtime serves (tests, seeded fixtures), and this is the same
    # seed for a compiled binary, which cannot borrow a harness gem's Backup.
    #
    # A page-level backup, not table-by-table SQL: it copies indexes and
    # sqlite_stat1 as they are, needs no list of tables, and cannot get insertion
    # order wrong against foreign keys. It REPLACES the destination, so schema DDL
    # already run against the empty database is superseded rather than conflicting.
    #
    # Runs on the pool's first connection: with a shared-cache in-memory database
    # every pooled handle sees one database, so seeding through one seeds all;
    # with a file database it is the same file. Boot-time only — a live reader
    # would hold a lock the backup has to wait for.
    def self.seed_from_file(src_path)
      dest = current_conn.dbh
      rc = SQLite3.sqlite3_open_v2(src_path, SQLite3.seed_out, SQLite3::OPEN_URI_RWC, nil)
      if rc != SQLite3::OK
        raise "Sqlx::Database.seed_from_file: cannot open " + src_path + " (" + rc.to_s + ")"
      end
      src = SQLite3.read_ptr(SQLite3.seed_out)
      bk = SQLite3.sqlite3_backup_init(dest, "main", src, "main")
      if bk.nil?
        # errmsg lives on the DESTINATION handle for a failed backup_init.
        msg = SQLite3.sqlite3_errmsg(dest)
        SQLite3.sqlite3_close(src)
        raise "Sqlx::Database.seed_from_file: backup_init failed: " + msg
      end
      step_rc = SQLite3.sqlite3_backup_step(bk, -1)
      SQLite3.sqlite3_backup_finish(bk)
      SQLite3.sqlite3_close(src)
      # DONE, not OK, is success for a completed step(-1); OK means pages remain,
      # which for -1 would mean it did not finish.
      if step_rc != SQLite3::DONE
        raise "Sqlx::Database.seed_from_file: backup_step(" + src_path + ") -> " + step_rc.to_s
      end
      # The fixture ships without sqlite_stat1, and an unplanned database
      # misplans the hottest-stories SELECT into a full-table walk plus a
      # temp-btree sort instead of reading the index to the LIMIT. Every adapter
      # ANALYZEs its seeded copy for exactly this reason.
      exec("ANALYZE")
    end

    # Returns the stmt pointer; the caller advances with `step?`, reads columns
    # with `column_int` / `column_text`, and releases with `finalize`. The -1
    # length argument lets sqlite measure the SQL itself (NUL-terminated).
    def self.prepare(sql)
      current_conn.prepare_cached(sql)
    end

    # Advance one row. True means a row is ready, false means the statement
    # finished. A driver error raises — a failed step is not "no row". `sql` is
    # optional and only enriches the error message.
    def self.step?(stmt, sql = nil)
      current_conn.step_real(stmt, sql)
    end

    def self.column_int(stmt, i)
      SQLite3.sqlite3_column_int(stmt, i)
    end

    def self.column_float(stmt, i)
      SQLite3.sqlite3_column_double(stmt, i)
    end

    # The FFI `:str` return is already its own GC string, so the value survives
    # the next step or finalize on the same stmt; NULL reads as "".
    def self.column_text(stmt, i)
      s = SQLite3.sqlite3_column_text(stmt, i)
      s.nil? ? "" : s
    end

    # Nullable-column reads: NULL stays nil rather than collapsing to "" / 0.
    # These probe the column's storage class first.
    def self.column_int_opt(stmt, i)
      if SQLite3.sqlite3_column_type(stmt, i) == SQLite3::NULL_TYPE
        nil
      else
        SQLite3.sqlite3_column_int(stmt, i)
      end
    end

    def self.column_float_opt(stmt, i)
      if SQLite3.sqlite3_column_type(stmt, i) == SQLite3::NULL_TYPE
        nil
      else
        SQLite3.sqlite3_column_double(stmt, i)
      end
    end

    def self.column_text_opt(stmt, i)
      SQLite3.sqlite3_column_text(stmt, i)
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
      if SQLite3.sqlite3_column_type(stmt, i) == SQLite3::NULL_TYPE
        nil
      else
        SQLite3.sqlite3_column_int(stmt, i) != 0
      end
    end

    def self.column_count(stmt)
      SQLite3.sqlite3_column_count(stmt)
    end

    # `sqlite3_column_name` returns a pointer owned by the stmt; the FFI `:str`
    # return is its own GC string, so it survives the next step or finalize.
    def self.column_name(stmt, i)
      s = SQLite3.sqlite3_column_name(stmt, i)
      s.nil? ? "" : s
    end

    # "finalize" rewinds the cached stmt (reset cursor + clear bound params) so
    # the next call reuses it; real `sqlite3_finalize` runs only at pool close.
    def self.finalize(stmt)
      SQLite3.sqlite3_reset(stmt)
      SQLite3.sqlite3_clear_bindings(stmt)
    end

    # Placeholder binding. Bind one `?` param (1-based index) on a prepared stmt
    # before the first `step?`. The lowerer emits `bind_int`/`bind_text`/
    # `bind_bool` straight after `prepare` for queries carrying runtime WHERE
    # values, so those key the prepared-statement cache by shape. A cached stmt
    # was reset and cleared at its previous `finalize`, so re-binding starts clean.
    def self.bind_int(stmt, idx, value)
      SQLite3.sqlite3_bind_int64(stmt, idx, value)
    end

    def self.bind_text(stmt, idx, value)
      SQLite3.sqlite3_bind_text(stmt, idx, value, -1, -1)
    end

    # SQLite has no native bool — bind 0/1, matching `escape_bool`'s inline form
    # and the INTEGER affinity `t.boolean` columns get.
    def self.bind_bool(stmt, idx, value)
      SQLite3.sqlite3_bind_int64(stmt, idx, value ? 1 : 0)
    end

    # SQL-value escaping. Single-quote doubling matches sqlite's literal-string
    # syntax; non-string input goes through `to_s` first.
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

    # Render an integer list for `IN (...)` eager-load batches. An empty list
    # becomes "NULL", so `IN (NULL)` is valid SQL matching no rows (an empty
    # `IN ()` is a syntax error).
    def self.escape_int_list(ids)
      return "NULL" if ids.empty?

      ids.map { |i| i.to_i.to_s }.join(", ")
    end

    # SQLite stores booleans as 0/1 integers (no native bool type).
    def self.escape_bool(b)
      b ? "1" : "0"
    end

    # Read a boolean column: SQLite returns 0/1, widen to bool.
    def self.column_bool(stmt, idx)
      column_int(stmt, idx) != 0
    end

    # Internal helpers — private on purpose: the primitive surface documented
    # at the top of this file is the contract; these are free to change
    # without notice.

    # Render one raw value into its `?` slot by runtime type — the adapter-owned
    # half of `exec_write`. nil binds NULL, a Time renders in the stored form, and
    # anything else falls to text (the rule `escape_string` follows).
    def self.bind_params(stmt, params)
      i = 0
      while i < params.length
        v = params[i]
        if v.nil?
          SQLite3.sqlite3_bind_null(stmt, i + 1)
        elsif v.is_a?(Integer)
          SQLite3.sqlite3_bind_int64(stmt, i + 1, v)
        elsif v == true || v == false
          SQLite3.sqlite3_bind_int64(stmt, i + 1, v ? 1 : 0)
        elsif v.is_a?(Float)
          SQLite3.sqlite3_bind_double(stmt, i + 1, v)
        elsif v.is_a?(Time)
          SQLite3.sqlite3_bind_text(stmt, i + 1, v.to_fs(:db), -1, -1)
        else
          SQLite3.sqlite3_bind_text(stmt, i + 1, v.to_s, -1, -1)
        end
        i += 1
      end
    end

    # `cache_key_for(sql, values)` — the cache key for a statement with the
    # caller's values: the SQL text plus each value rendered by runtime type as
    # a length-prefixed token. Two different bind sets must be two different
    # keys (the prefix keeps one value's own punctuation from colliding with a
    # neighbour's); the rendering is the key's, nothing else's — the statement
    # still executes with real binds.
    def self.cache_key_for(sql, values)
      return sql if values.empty?
      key = sql
      i = 0
      while i < values.length
        token = cache_token_for(values[i])
        key = key + "\n" + token.length.to_s + ":" + token
        i += 1
      end
      key
    end

    # One bind value as its cache-key token — the same type dispatch
    # `bind_params` applies, rendered to text. The type letter keeps an Integer
    # 5 and a String "5" in different keys, and keeps nil out of the string
    # namespace.
    def self.cache_token_for(v)
      if v.nil?
        "n"
      elsif v.is_a?(Integer)
        "i" + v.to_s
      elsif v == true || v == false
        "b" + (v ? "1" : "0")
      elsif v.is_a?(Float)
        "f" + v.to_s
      elsif v.is_a?(Time)
        "t" + v.to_fs(:db)
      else
        "s" + v.to_s
      end
    end

    # The DatabaseConnection this thread reads and writes through. Inside a
    # `with_connection` scope the first database access checks one out; a scope
    # with no database access never checks one out. Before `require_leases!`
    # (boot, tests, one-shot dev — all single-fiber) an access outside a scope
    # falls back to the pool's first connection. After it — a server process —
    # there is no fallback: the pool leases one connection to one thread at a
    # time, so the first connection may be one another thread holds — sharing it
    # would join that thread's open transaction and race its statement cache.
    # An access with no scope there raises instead, naming the scope to wrap the
    # call in.
    def self.current_conn
      c = ensure_connection
      return c if !c.nil?
      if @lease_required
        raise "Sqlx::Database: no connection lease on this thread — wrap the call in Sqlx::Database.with_connection"
      end
      @pools[0].first
    end

    # Funnel hook: record one SQL string into the active capture, if any. A
    # single nil check when no capture is installed.
    def self.record_query(sql)
      @query_log.push(sql) unless @query_log.nil?
      if @sql_trace
        $stderr.puts "  SQL " + sql
      end
    end

    # Query-log capture — the test-side SQL-string log, the one instrument that
    # can see an N+1 a comparison of included associations is blind to.
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

    # Raw typed column read — the driver's native value: Integer for INTEGER,
    # Float for REAL, String for TEXT, nil for NULL.
    #
    # Dispatches on the STORAGE CLASS of the value in this row, not the column's
    # declared type: SQLite is dynamically typed, and only a per-row probe can
    # tell a stored 0 from NULL. Caching `sqlite3_column_decltype` once per
    # statement would diverge exactly when storage class and declaration disagree.
    #
    # Integers read through `sqlite3_column_int` (32-bit), matching `column_int`
    # and the hydration path; BLOB falls to the text read.
    def self.column_value(stmt, i)
      t = SQLite3.sqlite3_column_type(stmt, i)
      if t == SQLite3::NULL_TYPE
        nil
      elsif t == SQLite3::INTEGER_TYPE
        SQLite3.sqlite3_column_int(stmt, i)
      elsif t == SQLite3::FLOAT_TYPE
        SQLite3.sqlite3_column_double(stmt, i)
      else
        # The FFI's `:str` return is already its own GC string (built by strlen
        # at the boundary), so nothing here reaches sqlite's buffer after the call.
        SQLite3.sqlite3_column_text(stmt, i)
      end
    end

    # Nullable-column writes: nil renders NULL.
    def self.escape_string_opt(s)
      s.nil? ? "NULL" : escape_string(s)
    end

    # Walk a prepared statement into name-keyed rows — the one row-shape walk
    # `exec_write` and `exec_read` share. The release stays with the caller: a
    # write reads its count before `finalize`, a read hands the rows back. `sql`
    # is only for the error message.
    def self.read_rows(stmt, sql)
      ncols = column_count(stmt)
      names = []
      i = 0
      while i < ncols
        names.push(column_name(stmt, i))
        i += 1
      end
      rows = []
      while step?(stmt, sql)
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
    # The public surface is the high-level list in the file header. These names
    # are implementation details — cursor, column/bind readers, escape helpers,
    # query cache, and connection internals — and are private on purpose.
    private_class_method :read_rows, :current_conn, :pool_for_thread
    private_class_method :lease_checkout
    private_class_method :busy_wait
    private_class_method :prepare, :step?, :finalize
    private_class_method :bind_int, :bind_text, :bind_bool, :bind_params
    private_class_method :column_int, :column_float, :column_text, :column_count
    private_class_method :column_name, :column_int_opt, :column_float_opt
    private_class_method :column_text_opt, :column_time, :column_time_opt
    private_class_method :column_bool_opt, :column_bool, :column_value
    private_class_method :escape_string, :escape_string_opt, :escape_int
    private_class_method :escape_int_opt, :escape_time, :escape_time_opt
    private_class_method :escape_float_opt, :escape_bool, :escape_bool_opt
    private_class_method :escape_int_list
    private_class_method :capture_sql, :record_query
    private_class_method :cache_key_for, :cache_token_for
    private_class_method :seed_from_file
  end
end
