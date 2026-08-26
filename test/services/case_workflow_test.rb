require "test_helper"

class CaseWorkflowTest < ActiveSupport::TestCase
  test "human transitions follow the complete lifecycle graph and record attribution" do
    CaseWorkflow::TRANSITIONS.each do |from, targets|
      targets.each do |target|
        support_case = new_case
        set_status(support_case, from)
        occurred_at = Time.current

        CaseWorkflow.transition!(
          workspace: support_case.workspace,
          support_case: support_case,
          membership: memberships(:owner_support),
          to: target,
          reason: "Work advanced",
          occurred_at: occurred_at
        )

        change = support_case.status_changes.order(:id).last
        assert_equal [ from, target ], [ change.from_status, change.to_status ]
        assert_equal users(:owner), change.actor
        assert_equal "web", change.source
        assert_equal "Work advanced", change.reason
        assert_equal target, support_case.reload.status
      end
    end
  end

  test "illegal transitions and blank reasons do not change state or audit" do
    support_case = new_case

    assert_no_difference [ "SupportCaseStatusChange.count", "AuditEvent.count" ] do
      assert_raises(CaseWorkflow::InvalidTransition) do
        CaseWorkflow.transition!(workspace: support_case.workspace, support_case: support_case, membership: memberships(:owner_support), to: :closed, reason: "Skip")
      end
      assert_raises(ArgumentError) do
        CaseWorkflow.transition!(workspace: support_case.workspace, support_case: support_case, membership: memberships(:owner_support), to: :triaged, reason: " ")
      end
    end
    assert_equal "new", support_case.reload.status
  end

  test "members can work cases, viewers cannot, and only managers can assign or create tags" do
    member = Membership.create!(workspace: workspaces(:acme_support), user: users(:outsider), role: :member)
    viewer_user = User.create!(email_address: "viewer@example.com", password: "password12345", verified_at: Time.current)
    viewer = Membership.create!(workspace: workspaces(:acme_support), user: viewer_user, role: :viewer)
    support_case = new_case

    CaseWorkflow.prioritize!(workspace: support_case.workspace, support_case: support_case, membership: member, priority: :high)
    assert_equal "high", support_case.reload.priority

    assert_raises(Current::RoleAccessDenied) do
      CaseWorkflow.prioritize!(workspace: support_case.workspace, support_case: support_case, membership: viewer, priority: :urgent)
    end
    assert_raises(Current::RoleAccessDenied) do
      CaseWorkflow.assign!(workspace: support_case.workspace, support_case: support_case, membership: member, assignee: member)
    end
    assert_raises(Current::RoleAccessDenied) do
      CaseWorkflow.create_tag!(workspace: support_case.workspace, membership: member, name: "Escalated")
    end
    assert_raises(Current::RoleAccessDenied) do
      CaseWorkflow.assign!(workspace: support_case.workspace, support_case: support_case, membership: memberships(:owner_support), assignee: viewer)
    end
  end

  test "assignment fails closed for another workspace and is idempotent" do
    support_case = new_case

    assert_raises(ActiveRecord::RecordNotFound) do
      CaseWorkflow.assign!(
        workspace: support_case.workspace, support_case: support_case,
        membership: memberships(:owner_support), assignee: memberships(:outsider_beta)
      )
    end

    assert_difference "AuditEvent.count", 1 do
      CaseWorkflow.assign!(workspace: support_case.workspace, support_case: support_case, membership: memberships(:owner_support), assignee: memberships(:owner_support))
    end
    assert_no_difference "AuditEvent.count" do
      CaseWorkflow.assign!(workspace: support_case.workspace, support_case: support_case, membership: memberships(:owner_support), assignee: memberships(:owner_support))
    end
  end

  test "assignment locks the target membership before checking its role" do
    support_case = new_case
    queries = []
    subscriber = lambda do |_name, _started, _finished, _id, payload|
      queries << payload[:sql] if payload[:sql].include?('FROM "memberships"')
    end

    ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") do
      CaseWorkflow.assign!(
        workspace: support_case.workspace,
        support_case: support_case,
        membership: memberships(:owner_support),
        assignee: memberships(:owner_support)
      )
    end

    assert queries.any? { |sql| sql.include?("ORDER BY") && sql.include?("FOR UPDATE") }
  end

  test "priority, tags, and private notes are audited without their text" do
    support_case = new_case
    actor = memberships(:owner_support)
    tag = CaseWorkflow.create_tag!(workspace: support_case.workspace, membership: actor, name: "  Billing  ")

    CaseWorkflow.prioritize!(workspace: support_case.workspace, support_case: support_case, membership: actor, priority: :urgent)
    CaseWorkflow.tag!(workspace: support_case.workspace, support_case: support_case, membership: actor, tag: tag)
    note = CaseWorkflow.add_note!(workspace: support_case.workspace, support_case: support_case, membership: actor, body: "Private diagnosis")
    CaseWorkflow.untag!(workspace: support_case.workspace, support_case: support_case, membership: actor, tag: tag)

    assert_equal "Billing", tag.name
    assert note.readonly?
    assert_equal users(:owner), note.author
    refute AuditEvent.where("metadata::text LIKE ?", "%Private diagnosis%").exists?
    assert_equal %w[case.note_added case.priority_changed case.tag_added case.tag_removed], AuditEvent.last(4).map(&:action).sort
  end

  test "assignment and tag callbacks run only for the transaction that changes the case" do
    support_case = new_case
    actor = memberships(:owner_support)
    tag = CaseWorkflow.create_tag!(workspace: support_case.workspace, membership: actor, name: "Callback")
    callbacks = []

    2.times do
      CaseWorkflow.assign!(
        workspace: support_case.workspace, support_case:, membership: actor, assignee: actor
      ) { callbacks << :assigned }
      CaseWorkflow.tag!(
        workspace: support_case.workspace, support_case:, membership: actor, tag:
      ) { callbacks << :tagged }
    end

    assert_equal %i[assigned tagged], callbacks
  end

  test "audit failure rolls back a case mutation" do
    support_case = new_case
    original_record = AuditEvent.method(:record!)
    AuditEvent.singleton_class.define_method(:record!) { |**| raise ActiveRecord::RecordInvalid, AuditEvent.new }

    assert_raises(ActiveRecord::RecordInvalid) do
      CaseWorkflow.prioritize!(workspace: support_case.workspace, support_case: support_case, membership: memberships(:owner_support), priority: :urgent)
    end
    assert_equal "normal", support_case.reload.priority
  ensure
    AuditEvent.singleton_class.define_method(:record!, original_record) if original_record
  end

  test "database rejects bulk changes to status history and private notes" do
    support_case = new_case
    CaseWorkflow.transition!(
      workspace: support_case.workspace, support_case: support_case,
      membership: memberships(:owner_support), to: :triaged, reason: "Reviewed"
    )
    note = CaseWorkflow.add_note!(
      workspace: support_case.workspace, support_case: support_case,
      membership: memberships(:owner_support), body: "Private diagnosis"
    )
    change = support_case.status_changes.order(:id).last

    change_error = assert_raises(ActiveRecord::StatementInvalid) do
      SupportCaseStatusChange.transaction(requires_new: true) do
        SupportCaseStatusChange.where(id: change.id).update_all(reason: "Rewritten")
      end
    end
    note_error = assert_raises(ActiveRecord::StatementInvalid) do
      CaseNote.transaction(requires_new: true) { CaseNote.where(id: note.id).delete_all }
    end

    assert_includes change_error.message, "helpdesk records are append-only"
    assert_includes note_error.message, "helpdesk records are append-only"
    assert_equal "Reviewed", change.reload.reason
    assert_equal "Private diagnosis", note.reload.body
  end

  private
    def new_case
      ConversationThread.start!(
        workspace: workspaces(:acme_support), contact: contacts(:alice),
        membership: memberships(:owner_support), occurred_at: Time.current
      ).support_case
    end

    def set_status(support_case, status)
      terminal_time = Time.current
      support_case.update!(
        status: status,
        status_changed_at: terminal_time,
        resolved_at: %w[resolved closed].include?(status) ? terminal_time : nil,
        closed_at: status == "closed" ? terminal_time : nil
      )
    end
end
