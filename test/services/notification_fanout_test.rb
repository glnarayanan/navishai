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
