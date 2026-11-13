# The queue retention job — deletes finished queue rows and ledger
# occurrences once they pass the retention window, in bounded batches
# so a large backlog never becomes one long write. Retention is a
# policy call, so this job ships OFF the clock: core never registers
# it, and an app opts in with its own `ActiveJob.recurring` line in
# `config/environment.rb` (the `generate job_queue` output prints that
# line commented out). An app that keeps history longer reopens this
# class and replaces `RETENTION`. Without it finished rows accumulate —
# each one is still the run's history.
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
