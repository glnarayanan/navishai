class MemoryIndexJob < ApplicationJob
  queue_as :background

  def perform(entry_id)
    MemoryIndexer.perform!(entry: MemoryIndexEntry.find(entry_id))
  end
end
