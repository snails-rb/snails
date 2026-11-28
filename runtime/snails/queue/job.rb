# The queue row model (`snails_queue_jobs`): one row per job, and a finished
# row is that run's history. Row transitions live here, not in the adapter.
#
# Column declarations are written out, and the DDL under `scaffold/queue/` is
# pinned to them by the harness contract test.
module Snails
  module Queue
    class Job < Sqlx::Base
      def self.table_name = "snails_queue_jobs"

      # The projected columns — every column the queue row carries, in DDL
      # order, with a reader generated for each (the hash-backed accessor
      # loop: spinel unrolls a literal array in the class body). The list
      # is the whole projection contract — `only_columns` derives from it
      # and the readers read through `read_attribute` — so a new DDL column
      # joins it in one place; the harness contract test compares it with
      # the template's `PRAGMA table_info`, and the declared type
      # exceptions below must stay inside it.
      COLUMNS = %w[id name payload status scheduled_at started_at finished_at attempts last_error created_at updated_at].each { |column| define_method(column) { read_attribute(column) } }

      def self.only_columns = COLUMNS.map { |c| c.to_sym }

      # Time columns: the storage time comes back as a `Time` (the
      # built-in timestamp pair plus the queue's own three). The list
      # replaces the default wholesale, so the pair is spelled again.
      def self.datetime_columns = %w[scheduled_at started_at finished_at created_at updated_at]

      # `payload` stores JSON as text — the DDL column type is TEXT, and
      # DDL alone cannot say "JSON" — so the codec pair is a declaration
      # here: write entries encode at the entry, the default `from_row`
      # decodes, and callers only ever see the logical value.
      def self.json_columns = %w[payload]

      # write one pending row. The payload is the logical value — the write entry
      # encodes the declared JSON column before it reaches the database.
      #
      # @param name [String] the job's name — the stored constant path
      # @param payload [Object, nil] the serializable arguments (nil for
      #   a payload-less job)
      # @param scheduled_at [Time] when the row becomes due — now for a
      #   plain enqueue, the run time for a delayed one, the interval's
      #   start for a recurring occurrence
      # @param now [Time] the created/updated timestamp for the row
      # @return [void]
      def self.enqueue!(name, payload, scheduled_at, now)
        create!({ name: name, payload: payload, status: "pending",
                  scheduled_at: scheduled_at, created_at: now, updated_at: now })
      end

      # atomically claim the oldest pending row whose time has come and return
      # the row as the database returned it: the pick and the state change are
      # one UPDATE (with RETURNING), so two workers can never carry the same
      # row, and a row scheduled for later stays untouched. The outer
      # `status = 'pending'` guard is what makes the claim atomic under READ
      # COMMITTED: a second claim that waited on the row lock re-evaluates the
      # outer condition and sees `running` instead of claiming again.
      #
      # The row format lets a caller record a delivery failure whose payload
      # cannot be decoded: building the Job record raises before a record
      # exists, but the claimed id, name, and attempts are already in hand.
      #
      # @param now [Time] the claim clock — rows scheduled after it stay
      # @return [Hash{String => Object}, nil] the claimed row's projected
      #   columns (`id`, `name`, `payload`, `attempts`, `created_at`,
      #   `scheduled_at`), nil when nothing is due
      def self.claim_due_row(now)
        rows = Sqlx::Base.write("UPDATE " + table_name +
                                " SET status = 'running', started_at = ?" +
                                ", attempts = attempts + 1, updated_at = ?" +
                                " WHERE id = (SELECT id FROM " + table_name +
                                " WHERE status = 'pending' AND scheduled_at <= ?" +
                                " ORDER BY id LIMIT 1)" +
                                " AND status = 'pending'" +
                                " RETURNING id, name, payload, attempts, created_at, scheduled_at",
                                [ now, now, now ])
        return nil if rows.length == 0
        rows[0]
      end

      # claim the oldest due row and build its Job record: the convenience
      # form for callers that treat a payload decode failure as an error.
      #
      # @param now [Time] the claim clock
      # @return [Snails::Queue::Job, nil] the claimed record, nil when nothing
      #   is due
      def self.claim_due(now)
        row = claim_due_row(now)
        return nil if row.nil?
        from_row(row)
      end

      # The status updates write by id and do not re-read the row: the caller
      # does not use a record, and a delivery failure's payload may not be
      # decodable — a re-read would fail on the very row being updated.

      # record a finished run on its row: the status and the finish timestamp
      # make the row the execution history.
      #
      # @param id [Integer] the row's id
      # @param now [Time] the finish timestamp
      # @return [void]
      def self.mark_succeeded!(id, now)
        update_all!({ id: id }, { status: "succeeded", finished_at: now, updated_at: now })
      end

      # return a claimed row to pending with a later run time: the row is not
      # finished, it is waiting for a process that can run it. `started_at` is
      # cleared so a pending row never looks like a run in progress, and the
      # reason stays on `last_error` while it waits.
      #
      # @param id [Integer] the row's id
      # @param scheduled_at [Time] when the row becomes claimable again
      # @param error [String] why the run was deferred
      # @param now [Time] the updated timestamp
      # @return [void]
      def self.mark_deferred!(id, scheduled_at, error, now)
        update_all!({ id: id }, { status: "pending", started_at: nil,
                                  scheduled_at: scheduled_at, last_error: error, updated_at: now })
      end

      # record a failed run on its row, with the error message: a delivery dead
      # letter and a raising body both land here, so a failure never passes
      # silently.
      #
      # @param id [Integer] the row's id
      # @param error [String] the failure message
      # @param now [Time] the finish timestamp
      # @return [void]
      def self.mark_failed!(id, error, now)
        update_all!({ id: id }, { status: "failed", finished_at: now, updated_at: now, last_error: error })
      end

      # retention delete in bounded batches: finished rows (`succeeded`/`failed`)
      # past the window go, pending rows and recent history stay. One call removes
      # at most `limit` rows, so a large backlog never holds the write lock for
      # its whole drain — the caller repeats until a short batch says the backlog
      # is gone (`Snails::Queue::PruneJob` owns the loop).
      #
      # The statement is raw SQL because SQLite has no portable
      # `DELETE ... LIMIT` (the bundled build omits the compile option),
      # while `IN (SELECT ... LIMIT)` works on both backends. The inner
      # SELECT stays unordered on purpose: with an `ORDER BY`, SQLite
      # sorts every matching row before applying `LIMIT`, which would
      # read the whole match set anyway.
      #
      # @param finished_before [Time] the retention cutoff
      # @param limit [Integer] the most rows one call deletes (positive)
      # @return [Integer] the number of rows deleted (0 when none matched)
      # @raise [ArgumentError] limit is not a positive Integer
      def self.prune_finished!(finished_before, limit:)
        unless limit.is_a?(Integer) && limit > 0
          raise ArgumentError, "prune_finished!: limit must be a positive Integer, got " + limit.to_s
        end
        Sqlx::Database.exec_write(
          "DELETE FROM " + table_name +
          " WHERE id IN (SELECT id FROM " + table_name +
          " WHERE status IN ('succeeded', 'failed') AND finished_at < ? LIMIT ?)",
          [ finished_before, limit ]
        )["count"]
      end
    end
  end
end
