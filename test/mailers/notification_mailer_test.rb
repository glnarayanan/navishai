require "test_helper"

class NotificationMailerTest < ActionMailer::TestCase
  test "alert names the work without copying customer content" do
    workspace = workspaces(:acme_support)
    support_case = create_support_case(subject: "Private customer subject")
    event = AuditEvent.record!(
      action: "case.status_changed", source: :system, workspace:, actor_kind: :system,
      subject: support_case, metadata: { from_status: "draft_ready", to_status: "awaiting_human_review" }
    )
    NotificationFanout.call(event)
    notification = memberships(:owner_support).notifications.last

    email = NotificationMailer.alert(notification)

    assert_equal [ users(:owner).email_address ], email.to
    assert_equal "A case needs review · Acme Support", email.subject
    expected_path = Rails.application.routes.url_helpers.workspace_support_case_path(workspace, support_case)
    assert_includes email.text_part.body.to_s, expected_path
    assert_includes email.html_part.body.to_s, "Open in NavishAI"
    refute_includes email.body.to_s, "Private customer subject"
  end
end
