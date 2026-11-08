# The adapter's own surface on `Sqlx`: literal building, the dialect name,
# and the flat transaction.
#
# There is no connection object here — the adapter (`Sqlx::Database`,
# chosen by the app's `config/database.rb`) owns the handle, so these
# members answer directly off `Sqlx`. Statements are entry points
# elsewhere: a SELECT goes through `Query#rows_by_sql`, a parameterized
# write through `Query#write`.
#
# Kept apart from `base.rb`: the transaction uses begin/ensure, so it rides
# on its own file.
module Sqlx
  # a full SQL literal, quotes included for strings. Callers assembling a
  # statement by hand splice this in. A value written this way is INLINE, not
  # bound, so `Query#write` is the safer default for anything that arrived from
  # a request.
  #
  # A Time renders in the runtime's stored form — the same form the adapter
  # binds a Time in — so a literal and a bound value compare the same way.
  # A Date renders as its ISO text (the stored DATE form), so a date literal
  # and a date bind share one spelling.
  #
  # A boolean renders through the adapter for the same reason: SQLite
  # stores it as the integers 1/0, while PostgreSQL has no
  # boolean = integer operator and needs the quoted '1'/'0' literal.
  #
  # @param value [Object] the value to render as a literal
  # @return [String] the literal — `NULL`, the bare number, the adapter's
  #   boolean spelling (`1`/`0` on SQLite, `'1'`/`'0'` on PostgreSQL),
  #   the stored form for a Time, else the escaped single-quoted string
  # @example
  #   Sqlx.quote("a'b")  # => "'a''b'"
  def self.quote(value)
    Sqlx::Database.quote(value)
  end

  # the dialect the running adapter speaks. Apps branch on it to pick SQL a
  # dialect understands; each adapter answers its own name through
  # `Sqlx::Database`.
  #
  # @return [String] the adapter's name ("SQLite", "PostgreSQL")
  def self.adapter_name
    Sqlx::Database.adapter_name
  end
end

module Sqlx
  class Base
    # the block inside BEGIN/COMMIT, with ROLLBACK + re-raise on any exception.
    # The rollback covers `Exception`, not just `StandardError`: a `ScriptError`
    # or a signal escaping the block must not leave the transaction open on a
    # pooled connection — the next lease would run inside it and keep its write
    # lock. The `ensure` runs on every exit path, including a failing COMMIT. A
    # lost connection has nothing left to roll back, so its `ConnectionFailed`
    # must not replace the error that ended the block. Flat transactions only: a
    # nested BEGIN would error in SQLite rather than silently join, which is the
    # honest failure.
    #
    # @return [Object] the block's value; an exception rolls the
    #   transaction back and is re-raised
    def self.transaction
      Sqlx::Database.exec("BEGIN")
      committed = false
      result = nil
      begin
        result = yield
        Sqlx::Database.exec("COMMIT")
        committed = true
      ensure
        unless committed
          begin
            Sqlx::Database.exec("ROLLBACK")
          rescue Sqlx::ConnectionFailed
            # The session is gone; there is nothing left to roll back. Keep
            # the original failure (or the failed COMMIT) as the unit's error.
          end
        end
      end
      result
    end
  end
end
