require "test_helper"

class NotificationFanoutTest < ActiveSupport::TestCase
  test "assignment notifies the assigned member once and not the actor" do
    workspace = workspaces(:acme_support)
    assignee = workspace.memberships.create!(user: users(:teammate), role: :member)
    support_case = create_support_case
    event = AuditEvent.record!(
      action: "case.assigned", source: :web, workspace:, actor: users(:owner), subject: support_case,
      metadata: { assignee_id: assignee.id }
    )

    assert_difference "Notification.count", 1 do
      assert_equal 1, NotificationFanout.call(event)
    end
    assert_no_difference "Notification.count" do
      NotificationFanout.call(event)
    end

    notification = assignee.notifications.sole
    assert notification.category_assignment?
    assert_equal Rails.application.routes.url_helpers.workspace_support_case_path(workspace, support_case), notification.path
    assert_equal event, notification.source_audit_event
    assert_empty memberships(:owner_support).notifications
  end

  test "review status notifies managers when a case is unassigned" do
    workspace = workspaces(:acme_support)
    support_case = create_support_case
    event = AuditEvent.record!(
      action: "case.status_changed", source: :system, workspace:, actor_kind: :system, subject: support_case,
      metadata: { from_status: "draft_ready", to_status: "awaiting_human_review" }
    )

    assert_difference "memberships(:owner_support).notifications.count", 1 do
      NotificationFanout.call(event)
    end
    assert memberships(:owner_support).notifications.last.category_review?
  end

  test "due intervention notices notify only the current writable assignee" do
    workspace = workspaces(:acme_support)
    owner = memberships(:owner_support)
    account = accounts(:acme)
    member = workspace.memberships.create!(
      user: User.create!(email_address: "due-fanout-#{SecureRandom.hex(3)}@example.com",
        password: "password12345", verified_at: Time.current),
      role: :member
    )
    other = workspace.memberships.create!(
      user: User.create!(email_address: "due-fanout-other-#{SecureRandom.hex(3)}@example.com",
        password: "password12345", verified_at: Time.current),
      role: :member
    )
    assessment = AccountHealth.recalculate!(
      workspace:, account:, trigger_kind: "human_request", membership: owner
    )
    plan, = create_reviewed_intervention_plan(workspace:, account:, membership: owner, assessment:)
    intervention = propose_test_intervention(
      workspace:, account:, membership: owner, accountable_membership: member,
      assessment:, artifact: plan, at: 2.days.ago
    )
    CustomerSuccessInterventionWorkflow.reschedule!(
      workspace:, membership: owner, intervention:, target_on: Date.current,
      reason: "Move the follow-up onto the due notice date."
    )
    CustomerSuccessInterventionDueNotices.deliver!(workspace:, as_of: Date.current)
    event = intervention.due_notices.sole.source_audit_event

    assert_equal 1, NotificationFanout.call(event)
    assert_equal 1, member.notifications.count
    assert_empty other.notifications
    assert_includes member.notifications.sole.title, "due today"

    CustomerSuccessInterventionWorkflow.reassign!(
      workspace:, membership: owner, intervention:, accountable_membership: other,
      reason: "Coverage moved before a repeated fanout."
    )
    assert_equal 0, NotificationFanout.call(event)
    assert_equal 1, member.notifications.count
    assert_empty other.notifications
  end

  test "routine status changes do not notify" do
    workspace = workspaces(:acme_support)
    support_case = create_support_case
    event = AuditEvent.record!(
      action: "case.status_changed", source: :web, workspace:, actor: users(:owner), subject: support_case,
      metadata: { from_status: "new", to_status: "triaged" }
    )

    assert_no_difference "Notification.count" do
      assert_equal 0, NotificationFanout.call(event)
    end
  end
end
