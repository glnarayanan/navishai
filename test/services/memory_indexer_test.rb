require "test_helper"

class MemoryIndexerTest < ActiveSupport::TestCase
  setup do
    @workspace = workspaces(:acme_support)
    @memory = @workspace.memory_records.create!(
      capture_key: "index-test", memory_type: :episodic, scope_kind: :workspace,
      topic: "index-test", content: "Durable source content", authority: :source_record,
      origin_kind: :system, source_reference: "test://index", source_digest: Digest::SHA256.hexdigest("source"),
      observed_at: Time.current, valid_from: Time.current, confidence: 1, retention_policy: :indefinite
    )
    @entry = @workspace.memory_index_entries.create!(memory_record: @memory)
  end

  test "indexes by immutable memory key and does not repeat a completed entry" do
    calls = []
    engine = Object.new
    engine.define_singleton_method(:index) do |document:|
      calls << document
      MemoryEngine::IndexReceipt.new(document_id: "document-1", status: "done")
    end

    MemoryIndexer.perform!(entry: @entry, engine: engine)
    MemoryIndexer.perform!(entry: @entry.reload, engine: engine)

    assert_equal 1, calls.size
    assert_equal @memory.memory_key, calls.sole.memory_key
    assert @entry.reload.indexed?
    assert_equal "document-1", @entry.external_document_id
    assert_equal 1, @entry.attempt_count
    assert @entry.indexed_at
  end

  test "persists ambiguous and definite failures for later reconciliation" do
    ambiguous = Object.new
    ambiguous.define_singleton_method(:index) { |document:| raise SupermemoryEngine::AmbiguousResult, document.memory_key }
    MemoryIndexer.perform!(entry: @entry, engine: ambiguous)
    assert @entry.reload.unknown?
    assert_equal "ambiguous_result", @entry.failure_code

    unavailable = Object.new
    unavailable.define_singleton_method(:index) { |document:| raise SupermemoryEngine::Unavailable, document.memory_key }
    MemoryIndexer.perform!(entry: @entry, engine: unavailable)
    assert @entry.reload.failed?
    assert_equal "unavailable", @entry.failure_code
    assert_equal 2, @entry.attempt_count
  end

  test "database freezes index identity" do
    assert_raises(ActiveRecord::StatementInvalid) do
      MemoryIndexEntry.transaction(requires_new: true) do
        MemoryIndexEntry.where(id: @entry.id).update_all(memory_record_id: @memory.id + 1)
      end
    end
    assert_equal @memory, @entry.reload.memory_record
  end
end
