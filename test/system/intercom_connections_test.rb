require "application_system_test_case"

class IntercomConnectionsTest < ApplicationSystemTestCase
  test "owner configures an Intercom connection on desktop and mobile" do
    sign_in(users(:owner))
    visit workspace_shared_email_inboxes_path(workspaces(:acme_support))
    click_on "Intercom", match: :first

    assert_selector "h1", text: "Intercom sync"
    fill_in "Connection name", with: "Support Intercom"
    fill_in "Intercom app ID", with: "app_123"
    fill_in "Credential key", with: "support"
    click_on "Add connection"

    assert_text "Intercom connection added."
    assert_text "app_123"
    assert_text "/webhooks/intercom/"
    click_on "Pause"
    assert_text "Intercom connection updated."
    assert_text "Paused"

    page.current_window.resize_to(320, 844)
    assert_equal 0, page.evaluate_script("Math.max(0, document.documentElement.scrollWidth - window.innerWidth)")
    page.all("input, button, a.button").first(5).each do |control|
      assert_operator control.rect.height, :>=, 48
    end
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
