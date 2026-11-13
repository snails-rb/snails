# The queue row model (`snails_queue_jobs`) — one row per job, and a
# finished row (`succeeded`/`failed`) is that run's history. Row
# transitions (claim, finish writes, orphan release, retention
# delete) live here; the adapter (`ActiveJob::DatabaseQueue`) composes
# its protocol over them and owns no table knowledge.
#
# The column declarations are written out, not generated: this is core
# code, and the generator that feeds app models (`gen-model-columns`)
# scans the app tree only. The queue DDL under `scaffold/queue/` is the
# other half of the declaration — the harness contract test pins the
# template and these declarations together, so a schema change cannot
# drift from the model.
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
      #   plain hand-off, the run time for a delayed one, the interval's
      #   start for a recurring occurrence
      # @param now [Time] the created/updated stamp for the row
      # @return [void]
      def self.enqueue!(name, payload, scheduled_at, now)
        create!({ name: name, payload: payload, status: "pending",
                  scheduled_at: scheduled_at, created_at: now, updated_at: now })
      end

      # atomically claim the oldest pending row whose time has come: the pick and
      # the state change are one UPDATE (with RETURNING), so two workers can never
      # carry the same row, and a row scheduled for later stays untouched. The
      # outer `status = 'pending'` guard is what makes the claim atomic under READ
      # COMMITTED: a second claim that waited on the row lock re-evaluates the
      # outer condition and sees `running` instead of claiming again. The returned
      # instance carries the projected id, name, payload, and attempts — what a
      # drain needs to run the job and name that run in its log.
      #
      # @param now [Time] the claim clock — rows scheduled after it stay
      # @return [Snails::Queue::Job, nil] the claimed row, nil when nothing
      #   is due
      def self.claim_due(now)
        rows = Sqlx::Base.write("UPDATE " + table_name +
                                " SET status = 'running', started_at = ?" +
                                ", attempts = attempts + 1, updated_at = ?" +
                                " WHERE id = (SELECT id FROM " + table_name +
                                " WHERE status = 'pending' AND scheduled_at <= ?" +
                                " ORDER BY id LIMIT 1)" +
                                " AND status = 'pending'" +
                                " RETURNING id, name, payload, attempts",
                                [ now, now, now ])
        return nil if rows.length == 0
        from_row(rows[0])
      end

      # return rows claimed by a dead process to pending: a claim older than the
      # cutoff is the only evidence needed (at-least-once — the attempts counter
      # keeps the lost run).
      #
      # @param started_before [Time] the claim-age cutoff
      # @param now [Time] the updated stamp for the released rows
      # @return [Integer] the number of rows returned to pending
      def self.release_orphaned!(started_before, now)
        update_all!({ status: "running", started_at: { lt: started_before } },
                    { status: "pending", updated_at: now })
      end

      # record a finished run on its row: the status and the finish stamp make the
      # row the execution history.
      #
      # @param id [Integer] the row's id
      # @param now [Time] the finish stamp
      # @return [void]
      def self.mark_succeeded!(id, now)
        update!(id, { status: "succeeded", finished_at: now, updated_at: now })
      end

      # record a failed run on its row, with the error message: an unresolvable
      # name and a raising body both land here, so a failure never passes
      # silently.
      #
      # @param id [Integer] the row's id
      # @param error [String] the failure message
      # @param now [Time] the finish stamp
      # @return [void]
      def self.mark_failed!(id, error, now)
        update!(id, { status: "failed", finished_at: now, updated_at: now, last_error: error })
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
