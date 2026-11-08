# The recurring-occurrence ledger (`snails_queue_occurrences`) — one
# row per (job_name, interval start). `ActiveJob::DatabaseQueue`'s
# `enqueue_once` writes the ledger and the queue row in one
# transaction: the ledger's unique key is what makes a recurring beat
# queue once when several processes fire it, and a collision is the
# answer "another process already queued this occurrence". A one-off
# `enqueue_at` never touches this table — one-off schedules carry no
# deduplication.
#
# Columns are declared here (core code — the app generator scans the
# app tree only); the DDL under `scaffold/queue/` is the other half,
# pinned by the harness contract test.
module Snails
  class QueueOccurrence < Sqlx::Base
    def self.table_name = "snails_queue_occurrences"

    # The projected columns — the ledger's identity and its write stamp,
    # with a reader generated for each (the hash-backed accessor loop:
    # one list, `only_columns` derives from it).
    COLUMNS = %w[job_name scheduled_at created_at].each { |column| define_method(column) { read_attribute(column) } }

    def self.only_columns = COLUMNS.map { |c| c.to_sym }

    # Time columns: identity (`scheduled_at`) and stamp (`created_at`)
    # come back as `Time`; the list replaces the default pair.
    def self.datetime_columns = %w[scheduled_at created_at]

    # put one occurrence on the ledger. The primary key is the idempotency: a
    # duplicate (job_name, scheduled_at) raises instead of overwriting, and the
    # caller turns that into "already queued". The row has no `id` column (the
    # key IS the pair), which is why the ledger brings its own insert instead of
    # the id-based `create!` re-read.
    #
    # @param job_name [String] the job's name — the stored constant path
    # @param scheduled_at [Time] the interval's start
    # @param now [Time] the created stamp
    # @return [void]
    # @raise [Sqlx::RecordNotUnique] this occurrence is already on the
    #   ledger
    def self.insert!(job_name, scheduled_at, now)
      Sqlx::Base.write("INSERT INTO " + table_name +
                       " (job_name, scheduled_at, created_at) VALUES (?, ?, ?)",
                       [ job_name, scheduled_at, now ])
    end

    # retention delete for the ledger in bounded batches: occurrences past the
    # window go, recent ones stay, and one call removes at most `limit` rows
    # (the caller repeats — `Snails::QueuePruneJob` owns the loop). The pair IN
    # the subquery is the ledger's primary key, so the delete needs no `id`
    # column; it works on both backends.
    #
    # @param scheduled_before [Time] the retention cutoff
    # @param limit [Integer] the most rows one call deletes (positive)
    # @return [Integer] the number of rows deleted (0 when none matched)
    # @raise [ArgumentError] limit is not a positive Integer
    def self.prune_before!(scheduled_before, limit:)
      unless limit.is_a?(Integer) && limit > 0
        raise ArgumentError, "prune_before!: limit must be a positive Integer, got " + limit.to_s
      end
      Sqlx::Database.exec_write(
        "DELETE FROM " + table_name +
        " WHERE (job_name, scheduled_at) IN" +
        " (SELECT job_name, scheduled_at FROM " + table_name +
        " WHERE scheduled_at < ? LIMIT ?)",
        [ scheduled_before, limit ]
      )["count"]
    end
  end
end
