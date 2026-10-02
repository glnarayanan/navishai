require "application_system_test_case"

class LabShellTest < ApplicationSystemTestCase
  test "auth workspace error and themes render at desktop and mobile sizes" do
    [ 1280, 390, 320 ].each do |width|
      page.current_window.resize_to(width, 900)
      visit new_session_path
      assert_selector "h1", text: "Sign in"
      assert_no_horizontal_overflow
      assert_no_csp_violations
      capture("auth-#{width}")
      fill_in "Email address", with: "owner@example.com"
      fill_in "Password", with: "wrong-password"
      click_button "Sign in"
      assert_selector "[role=alert]"
      capture("auth-error-#{width}")
      fill_in "Email address", with: "owner@example.com"
      fill_in "Password", with: "password12345"
      click_button "Sign in"
      assert_selector "h1", text: "Choose a workspace"
      click_link "Open lab", match: :first
      assert_selector "h2", text: "A clean starting point"
      assert_no_horizontal_overflow
      assert_no_csp_violations
      capture("workspace-#{width}")
      find(".theme-toggle").click
      find("[data-theme-value=dark]").click
      assert_selector "html.dark"
      capture("workspace-dark-#{width}")
      find(".theme-toggle").click
      find("[data-theme-value=light]").click
      find(".lab-navigation summary").click
      click_button "Sign out"
    end
  end

  test "keyboard navigation and Owner-only settings remain accessible" do
    visit new_session_path
    page.driver.browser.action.send_keys(:tab).perform
    assert_equal "Skip to content", page.evaluate_script("document.activeElement.textContent")
    sign_in users(:teammate)
    visit edit_workspace_path(workspaces(:acme_success))
    assert_selector "h1", text: "You don’t have access to this action"
    assert_no_horizontal_overflow
    capture("permission-error")
  end

  private
    def capture(name)
      return unless ENV["CAPTURE_LAB_SCREENSHOTS"] == "1"

      path = Rails.root.join(".amp/in/artifacts/phase-a/#{name}.png")
      FileUtils.mkdir_p(path.dirname)
      save_screenshot(path)
    end
end
