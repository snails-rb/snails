# The queue retention job: delete finished queue rows and ledger occurrences
# past the retention window, in bounded batches so a backlog stays short.
#
# Retention is a policy call, so core never schedules this job; an app opts in
# with its own `ActiveJob.recurring` line and may replace `RETENTION`.
module Snails
  module Queue
    class PruneJob < ActiveJob::Base
      # How long finished rows and ledger occurrences are kept.
      RETENTION = 7.days

      # The most rows one delete removes. A pass repeats while a full
      # batch comes back, so a million-row backlog never holds one write
      # lock for its whole drain.
      PRUNE_BATCH_SIZE = 1000

      # one prune run: both tables share the window, so a queue and its ledger
      # never disagree about what is old. Each table repeats its bounded delete
      # until a short batch says the backlog is gone. Carries no payload (the beat
      # passes nil).
      #
      # @param data [Object, nil] unused — a recurring beat carries none
      # @return [void]
      def self.perform(data)
        before = RETENTION.ago
        prune_finished_queue_rows(before)
        prune_occurrence_rows(before)
      end

      # Delete finished queue rows in batches until a pass returns less
      # than a full batch.
      def self.prune_finished_queue_rows(before)
        while true
          deleted = Snails::Queue::Job.prune_finished!(before, limit: PRUNE_BATCH_SIZE)
          break if deleted < PRUNE_BATCH_SIZE
        end
      end

      # The ledger's half of the same sweep — occurrences carry no status,
      # so every row past the window goes.
      def self.prune_occurrence_rows(before)
        while true
          deleted = Snails::Queue::Occurrence.prune_before!(before, limit: PRUNE_BATCH_SIZE)
          break if deleted < PRUNE_BATCH_SIZE
        end
      end

      private_class_method :prune_finished_queue_rows, :prune_occurrence_rows
    end
  end
end
