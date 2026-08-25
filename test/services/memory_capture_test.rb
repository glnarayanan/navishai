require "test_helper"

class MemoryCaptureTest < ActiveSupport::TestCase
  setup do
    @workspace = workspaces(:acme_support)
    @owner = memberships(:owner_support)
    @support_case = create_support_case
  end

  test "captures messages and case outcomes once through closure" do
    message = add_inbound_message(@support_case, body: "The export still fails.")
    transition(:triaged, "Reviewed")
    transition(:investigating, "Assigned")
    transition(:resolved, "Export configuration corrected")
    transition(:closed, "Customer confirmed the export")

    memories = @workspace.memory_records.where(support_case: @support_case).order(:id)
    assert_equal 3, memories.count
    assert_equal %w[conversation-message case-outcome case-outcome], memories.pluck(:topic)
    assert_equal "Customer message: The export still fails.", memories.first.content
    assert_equal "Case resolved: Export configuration corrected", memories.second.content
    assert_equal "Case closed: Customer confirmed the export", memories.third.content
    assert_equal 3, @workspace.memory_index_entries.where(memory_record: memories).count
    assert_equal 3, AuditEvent.where(workspace: @workspace, action: "memory.record_captured", subject_id: memories).count

    assert_no_difference [ "MemoryRecord.count", "MemoryIndexEntry.count", "AuditEvent.count" ] do
      assert_equal memories.first, MemoryCapture.message!(workspace: @workspace, message: message)
    end
  end

  test "capture failure rolls back the owning conversation transaction" do
    original = MemoryCapture.method(:message!)
    MemoryCapture.define_singleton_method(:message!) { |**| raise ActiveRecord::Rollback }

    assert_no_difference [ "ConversationMessage.count", "MemoryRecord.count", "MemoryIndexEntry.count" ] do
      result = ConversationThread.append_inbound!(
        workspace: @workspace, conversation: @support_case.conversation,
        author: @support_case.conversation.contact, body: "Do not retain a partial event.",
        occurred_at: Time.current, source: :integration
      )
      assert_nil result
    end
  ensure
    MemoryCapture.define_singleton_method(:message!, original) if original
  end

  private
    def transition(status, reason)
      CaseWorkflow.transition!(
        workspace: @workspace, support_case: @support_case, membership: @owner,
        to: status, reason: reason, occurred_at: Time.current
      )
    end
end
