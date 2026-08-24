require "test_helper"

class NotificationsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @workspace = workspaces(:acme_support)
    @membership = memberships(:owner_support)
    @support_case = create_support_case
    event = AuditEvent.record!(
      action: "case.status_changed", source: :system, workspace: @workspace, actor_kind: :system,
      subject: @support_case, metadata: { from_status: "draft_ready", to_status: "awaiting_human_review" }
    )
    NotificationFanout.call(event)
    @notification = @membership.notifications.last
  end

  test "member sees their notification and follows it as read" do
    sign_in_as users(:owner)

    get workspace_notifications_path(@workspace)
    assert_response :success
    assert_select "h1", "Notifications"
    assert_select ".notification-item.is-unread", count: 1
    assert_select ".nav-count", text: "1"

    patch workspace_notification_path(@workspace, @notification)
    assert_redirected_to workspace_support_case_path(@workspace, @support_case)
    assert @notification.reload.read_at?
  end

  test "member cannot read another workspace notification" do
    beta_membership = memberships(:outsider_beta)
    foreign_event = AuditEvent.record!(
      action: "case.assigned", source: :system, workspace: beta_membership.workspace,
      actor_kind: :system, metadata: { assignee_id: beta_membership.id }
    )
    foreign = NotificationFanout.call(foreign_event).then { beta_membership.notifications.last }
    sign_in_as users(:owner)

    patch workspace_notification_path(@workspace, foreign)
    assert_response :not_found
    assert_nil foreign.reload.read_at
  end

  test "mark all read affects only the current member" do
    teammate = @workspace.memberships.create!(user: users(:teammate), role: :member)
    teammate.notifications.create!(
      source_audit_event: @notification.source_audit_event, workspace: @workspace,
      category: :review, title: "Teammate review", path: workspace_support_cases_path(@workspace),
      occurred_at: @notification.occurred_at
    )
    sign_in_as users(:owner)

    post read_all_workspace_notifications_path(@workspace)

    assert_redirected_to workspace_notifications_path(@workspace)
    assert @notification.reload.read_at?
    assert_nil teammate.notifications.last.read_at
  end
end
