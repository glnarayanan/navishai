class MemoryIndexer
  def self.perform!(entry:, engine: nil, attempted_at: Time.current)
    entry.with_lock do
      return entry if entry.indexed?
      return entry if entry.memory_record.memory_tombstone

      entry.update!(
        status: :indexing,
        attempt_count: entry.attempt_count + 1,
        external_document_id: nil,
        external_status: nil,
        failure_code: nil,
        last_attempted_at: attempted_at,
        indexed_at: nil
      )
    end

    engine ||= SupermemoryEngine.default
    receipt = engine.index(document: MemoryEngine::Document.from(entry.memory_record))
    entry.with_lock do
      indexed = receipt.status == "done"
      entry.update!(
        status: indexed ? :indexed : :queued,
        external_document_id: receipt.document_id,
        external_status: receipt.status,
        failure_code: nil,
        indexed_at: indexed ? Time.current : nil
      )
    end
  rescue SupermemoryEngine::AmbiguousResult
    record_failure(entry, :unknown, "ambiguous_result")
  rescue SupermemoryEngine::Error, SystemCallError, Timeout::Error => error
    record_failure(entry, :failed, error.class.name.demodulize.underscore.first(100))
  end

  def self.record_failure(entry, status, code)
    entry.with_lock do
      entry.update!(
        status: status,
        external_document_id: nil,
        external_status: nil,
        failure_code: code,
        indexed_at: nil
      )
    end
  end
  private_class_method :record_failure
end
