class MemoryDeletion
  def self.perform!(tombstone:, engine: nil, attempted_at: Time.current)
    tombstone.with_lock do
      return tombstone if tombstone.index_status_removed?
      return tombstone if tombstone.memory_record.memory_index_entry&.indexing?

      tombstone.update!(
        index_status: :removing, attempt_count: tombstone.attempt_count + 1,
        failure_code: nil, last_attempted_at: attempted_at, removed_at: nil
      )
    end

    record = tombstone.memory_record
    (engine || SupermemoryEngine.default).remove(
      organization_key: record.workspace.organization_id.to_s,
      workspace_key: record.workspace.runner_key,
      memory_key: record.memory_key
    )
    tombstone.with_lock do
      tombstone.update!(index_status: :removed, failure_code: nil, removed_at: Time.current)
    end
  rescue SupermemoryEngine::AmbiguousResult
    record_failure(tombstone, :unknown, "ambiguous_result")
  rescue SupermemoryEngine::Error, SystemCallError, Timeout::Error => error
    record_failure(tombstone, :failed, error.class.name.demodulize.underscore.first(100))
  end

  def self.record_failure(tombstone, status, code)
    tombstone.with_lock do
      tombstone.update!(index_status: status, failure_code: code, removed_at: nil)
    end
  end
  private_class_method :record_failure
end
