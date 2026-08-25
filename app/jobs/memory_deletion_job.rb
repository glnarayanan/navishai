class MemoryDeletionJob < ApplicationJob
  queue_as :background

  def self.enqueue_after_commit(tombstone)
    ActiveRecord.after_all_transactions_commit do
      perform_later(tombstone.id)
    rescue ActiveJob::EnqueueError
      Rails.logger.error("Memory deletion job enqueue failed for tombstone #{tombstone.id}")
    end
  end

  def perform(tombstone_id, wait_count = 0)
    tombstone = MemoryTombstone.find(tombstone_id)
    return if tombstone.workspace.deletion_requested?

    result = MemoryDeletion.perform!(tombstone:)
    if result.index_status_pending? && wait_count < 5
      self.class.set(wait: 30.seconds).perform_later(tombstone_id, wait_count + 1)
    end
  end
end
