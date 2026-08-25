require "application_system_test_case"

class SharedEmailInboxesTest < ApplicationSystemTestCase
  test "owner configures and pauses a shared email inbox on desktop and mobile" do
    sign_in(users(:owner))
    visit workspace_support_cases_path(workspaces(:acme_support))
    click_on "Email"

    assert_text "Shared email inboxes"
    fill_in "Inbox name", with: "Support"
    fill_in "Email address", with: "support@example.com"
    fill_in "Credential key", with: "support"
    click_on "Add inbox"

    assert_text "Email inbox added."
    assert_text "support@example.com"
    assert_text "/webhooks/shared-email/"
    click_on "Pause"
    assert_text "Email inbox updated."
    assert_text "Paused"

    page.current_window.resize_to(320, 844)
    assert_equal 0, page.evaluate_script("Math.max(0, document.documentElement.scrollWidth - window.innerWidth)")
    assert_selector "input, button", minimum: 4
    page.all("input, button").first(4).each do |control|
      assert_operator control.rect.height, :>=, 48
    end
    %w[Cases Email].each do |label|
      link = find_link(label)
      assert_operator link.rect.width, :>=, 48
      assert_operator link.rect.height, :>=, 48
    end

    click_on "Sign out"
    assert_selector "h1", text: "Sign in", wait: 6
    sign_in(users(:teammate))
    visit workspace_support_cases_path(workspaces(:acme_success))
    assert_no_link "Email"
  end

  private
    def sign_in(user)
      visit new_session_path
      fill_in "Email address", with: user.email_address
      fill_in "Password", with: "password12345"
      click_on "Sign in"
      assert_selector "h1", text: "Choose a workspace", wait: 6
    end
end
