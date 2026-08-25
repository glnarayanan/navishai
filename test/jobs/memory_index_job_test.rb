require "test_helper"

class MemoryIndexJobTest < ActiveJob::TestCase
  test "degraded indexing queues capture without repeated engine calls until explicit reconstruction" do
    workspace = workspaces(:acme_support)
    failed = create_entry(workspace, "failed")
    failed.update!(status: :indexing, attempt_count: 1, last_attempted_at: Time.current)
    failed.update!(status: :failed, failure_code: "offline")
    pending = create_entry(workspace, "pending")
    engine_calls = 0
    original = SupermemoryEngine.method(:default)
    engine = Object.new
    engine.define_singleton_method(:index) do |document:|
      engine_calls += 1
      MemoryEngine::IndexReceipt.new(document_id: document.memory_key, status: "done")
    end
    SupermemoryEngine.define_singleton_method(:default) { engine }

    MemoryIndexJob.perform_now(pending.id)
    assert pending.reload.pending?
    assert_equal 0, engine_calls

    MemoryIndexJob.perform_now(pending.id, true)
    assert pending.reload.indexed?
    assert_equal 1, engine_calls
  ensure
    SupermemoryEngine.define_singleton_method(:default, original)
  end

  private
    def create_entry(workspace, topic)
      memory = workspace.memory_records.create!(
        memory_type: :episodic, scope_kind: :workspace, topic:,
        content: "#{topic} memory", authority: :source_record, origin_kind: :system,
        source_reference: "test://#{topic}", source_digest: Digest::SHA256.hexdigest(topic),
        observed_at: 1.day.ago, valid_from: 1.day.ago, confidence: 1, retention_policy: :indefinite
      )
      workspace.memory_index_entries.create!(memory_record: memory)
    end
end
