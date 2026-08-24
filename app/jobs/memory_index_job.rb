class MemoryIndexJob < ApplicationJob
  queue_as :background

  def self.enqueue_after_commit(entry)
    ActiveRecord.after_all_transactions_commit do
      perform_later(entry.id)
    rescue ActiveJob::EnqueueError
      Rails.logger.error("Memory index job enqueue failed for entry #{entry.id}")
    end
  end

  def perform(entry_id)
    MemoryIndexer.perform!(entry: MemoryIndexEntry.find(entry_id))
  end
end
