class MemoryIndexJob < ApplicationJob
  queue_as :background

  def self.enqueue_after_commit(entry, force: false)
    ActiveRecord.after_all_transactions_commit do
      perform_later(entry.id, force)
    rescue ActiveJob::EnqueueError
      Rails.logger.error("Memory index job enqueue failed for entry #{entry.id}")
    end
  end

  def perform(entry_id, force = false)
    entry = MemoryIndexEntry.find(entry_id)
    return entry if !force && entry.workspace.memory_index_entries.where(status: %w[failed unknown]).exists?

    MemoryIndexer.perform!(entry:)
  end
end
