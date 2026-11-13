# Error classes the runtime raises and apps rescue. `RecordNotFound`,
# `RecordNotUnique`, `ValueTooLong`, and `RecordInvalid` keep their Active Record
# names, so existing rescue clauses still match.
module Sqlx
  # Raised when a lookup finds no matching row. `Sqlx::Base.find_by!`
  # and `find` raise it (message derived from `table_name`); apps also
  # raise it directly for an absent record and rescue it to map the miss to
  # an HTTP 404 at dispatch.
  class RecordNotFound < StandardError
    # The default message is explicit so every build answers the same string.
    def initialize(message = "Sqlx::RecordNotFound")
      super(message)
    end
  end

  # Raised when a value exceeds its column's declared limit. Apps also
  # construct it directly to reject over-long input before it reaches the
  # DB. No core raiser; retained as part of the error interface.
  class ValueTooLong < StandardError
    def initialize(message = "Sqlx::ValueTooLong")
      super(message)
    end
  end

  # Raised when an INSERT/UPDATE trips a unique index. Apps rescue it to
  # turn a lost race into a redirect rather than a 500.
  #
  # Raised by each `Sqlx::Database`, not from here: the driver error
  # surfaces in `Sqlx::Database.exec`, the only place holding it. The sqlite
  # adapter (`database/sqlite.rb`) maps it in `exec`, keyed on the engine's
  # own message text ("UNIQUE constraint failed: <table>.<column>"); the
  # PostgreSQL adapter maps its SQLSTATE.
  class RecordNotUnique < StandardError
    def initialize(message = "Sqlx::RecordNotUnique")
      super(message)
    end
  end

  # Raised when the database lock could not be taken inside the adapter's
  # wait budget (`PRAGMA busy_timeout`, 5 s on SQLite). The unit did not
  # commit, so the caller may retry the whole unit; retrying one statement
  # inside an open transaction is not safe, because the driver may have
  # already rolled that transaction back.
  #
  # Both adapters map their lock errors here: the sqlite adapter its driver
  # codes 5 (SQLITE_BUSY) and 6 (SQLITE_LOCKED), the PostgreSQL adapter the
  # SQLSTATEs 40P01 (deadlock detected), 55P03 (lock not available) and 40001
  # (serialization failure).
  class Busy < StandardError
    def initialize(message = "Sqlx::Busy")
      super(message)
    end
  end

  # Raised when a condition value cannot be cast to the column's declared
  # type. The model query layer raises it when a String is handed to an
  # integer column and is not a decimal integer; the dispatcher maps it to a
  # 400 (the request carried a malformed value, not a missing row). Apps that
  # want a different response rescue it explicitly.
  class CastError < StandardError
    def initialize(message = "Sqlx::CastError")
      super(message)
    end
  end

  # Raised when a connection-pool checkout could not get a connection inside
  # the adapter's wait budget. The statement did not run, so the caller may
  # retry the unit; a request that keeps hitting it needs a larger pool or a
  # shorter transaction, not a longer wait.
  class ConnectionTimeout < StandardError
    def initialize(message = "Sqlx::ConnectionTimeout")
      super(message)
    end
  end

  # Raised when a database connection fails: a statement finds the session
  # gone, or a checkout cannot get a healthy connection. When the failure
  # happened while a statement was running, the unit's outcome is unknown — it
  # may have committed — so retry the whole unit, never the statement alone.
  # The adapter discards a lost connection; a later checkout that finds no free
  # connection opens a replacement.
  class ConnectionFailed < StandardError
    def initialize(message = "Sqlx::ConnectionFailed")
      super(message)
    end
  end

  class RecordInvalid < StandardError
    attr_reader :record

    def initialize(record)
      @record = record
      super("Validation failed: #{record.errors.join(', ')}")
    end
  end
end
