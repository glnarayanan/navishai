require "test_helper"

class ConversationThreadTest < ActiveSupport::TestCase
  test "inbound resume is not a public case workflow command" do
    refute_respond_to CaseWorkflow, :resume_for_inbound!
  end

  test "start creates a conversation, case, initial history, and audits atomically" do
    now = Time.zone.parse("2026-08-23 12:00:00")

    assert_difference [ "Conversation.count", "SupportCase.count", "SupportCaseStatusChange.count" ], 1 do
      assert_difference "AuditEvent.count", 2 do
        @conversation = ConversationThread.start!(
          workspace: workspaces(:acme_support),
          contact: contacts(:alice),
          membership: memberships(:owner_support),
          subject: "  Login trouble  ",
          occurred_at: now
        )
      end
    end

    assert_equal "Login trouble", @conversation.subject
    assert_equal "new", @conversation.support_case.status
    change = @conversation.support_case.status_changes.sole
    assert_nil change.from_status
    assert_equal "new", change.to_status
    assert_equal users(:owner), change.actor
    assert_equal %w[case.created conversation.created], AuditEvent.last(2).map(&:action).sort
  end

  test "inbound messages resume waiting and terminal cases while preserving case work" do
    conversation = start_conversation
    support_case = conversation.support_case
    tag = CaseWorkflow.create_tag!(workspace: support_case.workspace, membership: memberships(:owner_support), name: "Billing")
    CaseWorkflow.assign!(workspace: support_case.workspace, support_case: support_case, membership: memberships(:owner_support), assignee: memberships(:owner_support))
    CaseWorkflow.prioritize!(workspace: support_case.workspace, support_case: support_case, membership: memberships(:owner_support), priority: :high)
    CaseWorkflow.tag!(workspace: support_case.workspace, support_case: support_case, membership: memberships(:owner_support), tag: tag)

    [ "waiting_customer", "resolved", "closed" ].each do |status|
      set_status(support_case, status)
      message = ConversationThread.append_inbound!(
        workspace: support_case.workspace,
        conversation: conversation,
        author: contacts(:alice),
        body: "Any update?",
        occurred_at: Time.current,
        source: :integration
      )

      assert message.readonly?
      assert_equal "investigating", support_case.reload.status
      assert_nil support_case.resolved_at
      assert_nil support_case.closed_at
      assert_equal memberships(:owner_support), support_case.assigned_membership
      assert_equal "high", support_case.priority
      assert_includes support_case.tags, tag
      assert_equal "new inbound message", support_case.status_changes.order(:id).last.reason
    end
  end

  test "inbound message in an active state does not change case status" do
    conversation = start_conversation

    assert_no_difference "SupportCaseStatusChange.count" do
      ConversationThread.append_inbound!(
        workspace: conversation.workspace,
        conversation: conversation,
        author: conversation.contact,
        body: "More context",
        occurred_at: 1.minute.from_now,
        source: :integration
      )
    end

    assert_equal "new", conversation.support_case.reload.status
    assert_equal 1.minute.from_now.to_i, conversation.reload.last_message_at.to_i
  end

  test "a delayed inbound message does not reopen a case changed after it occurred" do
    conversation = start_conversation
    support_case = conversation.support_case

    %w[waiting_customer resolved closed].each do |status|
      changed_at = Time.current
      set_status(support_case, status, at: changed_at)

      assert_no_difference "SupportCaseStatusChange.count" do
        ConversationThread.append_inbound!(
          workspace: conversation.workspace,
          conversation: conversation,
          author: conversation.contact,
          body: "Delayed message",
          occurred_at: changed_at - 1.minute,
          source: :integration
        )
      end

      assert_equal status, support_case.reload.status
      assert_equal changed_at.to_i, support_case.status_changed_at.to_i
    end
  end

  test "inbound append fails closed across workspaces and for the wrong contact" do
    conversation = start_conversation

    assert_no_difference [ "ConversationMessage.count", "AuditEvent.count" ] do
      assert_raises(ActiveRecord::RecordNotFound) do
        ConversationThread.append_inbound!(
          workspace: workspaces(:beta_support), conversation: conversation, author: contacts(:bob),
          body: "Wrong tenant", occurred_at: Time.current, source: :integration
        )
      end
      assert_raises(ActiveRecord::RecordNotFound) do
        ConversationThread.append_inbound!(
          workspace: workspaces(:acme_support), conversation: conversation, author: contacts(:alice_duplicate),
          body: "Wrong sender", occurred_at: Time.current, source: :integration
        )
      end
    end
  end

  test "audit failure rolls back message, timestamp, and reopen" do
    conversation = start_conversation
    set_status(conversation.support_case, "closed")
    original_record = AuditEvent.method(:record!)
    AuditEvent.singleton_class.define_method(:record!) { |**| raise ActiveRecord::RecordInvalid, AuditEvent.new }

    assert_no_difference "ConversationMessage.count" do
      assert_raises(ActiveRecord::RecordInvalid) do
        ConversationThread.append_inbound!(
          workspace: conversation.workspace, conversation: conversation, author: conversation.contact,
          body: "Please reopen", occurred_at: Time.current, source: :integration
        )
      end
    end
    assert_equal "closed", conversation.support_case.reload.status
    assert_nil conversation.reload.last_message_at
  ensure
    AuditEvent.singleton_class.define_method(:record!, original_record) if original_record
  end

  private
    def start_conversation
      ConversationThread.start!(
        workspace: workspaces(:acme_support), contact: contacts(:alice),
        membership: memberships(:owner_support), subject: "Help", occurred_at: Time.current
      )
    end

    def set_status(support_case, status, at: Time.current)
      support_case.update!(
        status: status,
        status_changed_at: at,
        resolved_at: %w[resolved closed].include?(status) ? at : nil,
        closed_at: status == "closed" ? at : nil
      )
    end
end
