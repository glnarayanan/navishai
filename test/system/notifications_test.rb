require "application_system_test_case"

class NotificationsTest < ApplicationSystemTestCase
  test "member reviews notifications on desktop and mobile" do
    workspace = workspaces(:acme_support)
    support_case = create_support_case
    event = AuditEvent.record!(
      action: "case.status_changed", source: :system, workspace:, actor_kind: :system,
      subject: support_case, metadata: { from_status: "draft_ready", to_status: "awaiting_human_review" }
    )
    NotificationFanout.call(event)

    sign_in
    click_link "Acme Support"
    click_link "Notifications"

    assert_selector "h1", text: "Notifications"
    assert_selector ".notification-item.is-unread", text: "A case needs review"
    assert_button "Mark all read"

    page.current_window.resize_to(320, 844)
    assert_operator page.evaluate_script("window.innerWidth"), :<=, 500
    assert_operator page.evaluate_script("document.documentElement.scrollWidth - window.innerWidth"), :<=, 0
    assert_operator find_button("Mark all read").evaluate_script("this.getBoundingClientRect().height"), :>=, 48
    assert_operator find(".notification-link").evaluate_script("this.getBoundingClientRect().height"), :>=, 48

    find(".notification-link").click
    assert_current_path workspace_support_case_path(workspace, support_case)
    assert @membership.reload.notifications.last.read_at?
  end

  private
    def sign_in
      @membership = memberships(:owner_support)
      visit new_session_path
      fill_in "Email address", with: @membership.user.email_address
      fill_in "Password", with: "password12345"
      click_button "Sign in"
    end
end
