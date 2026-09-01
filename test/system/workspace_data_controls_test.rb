require "application_system_test_case"

class WorkspaceDataControlsTest < ApplicationSystemTestCase
  test "owner reviews and queues content expiry at desktop and mobile widths" do
    workspaces(:acme_support).create_workspace_data_policy!(content_retention_days: 30, audit_retention_days: 365)
    sign_in
    click_link "Acme Support"
    click_link "Data & retention"

    assert_selector "h1", text: "Data controls"
    assert_text "No content expiry runs yet."
    assert_link "Download workspace export"
    reveal_setup "Import a workspace"
    assert_selector "h2", text: "Import a workspace"
    assert_field "New workspace name"
    assert_field "New workspace slug"
    assert_field "Compressed workspace export"
    reveal_setup "Delete workspace"
    assert_selector "h2", text: "Delete workspace"
    assert_field "Type support to confirm"

    page.current_window.resize_to(320, 844)
    assert_operator page.evaluate_script("window.innerWidth"), :<=, 500
    assert_operator page.evaluate_script("document.documentElement.scrollWidth - window.innerWidth"), :<=, 0
    assert_operator find_button("Run content expiry now").evaluate_script("this.getBoundingClientRect().height"), :>=, 48
    assert_operator find_button("Run audit expiry now").evaluate_script("this.getBoundingClientRect().height"), :>=, 48
    assert_operator find_link("Download workspace export").evaluate_script("this.getBoundingClientRect().height"), :>=, 48
    assert_operator find_button("Import as new workspace").evaluate_script("this.getBoundingClientRect().height"), :>=, 48
    assert_operator find_button("Verify backup and restore", disabled: true)
      .evaluate_script("this.getBoundingClientRect().height"), :>=, 48
    assert_operator find_button("Delete workspace").evaluate_script("this.getBoundingClientRect().height"), :>=, 48
    open_workspace_nav
    assert_operator find_link("Data & retention").evaluate_script("this.getBoundingClientRect().height"), :>=, 48
    find("body").send_keys(:escape)

    accept_confirm { click_button "Run content expiry now" }
    assert_text "Content expiry queued."
    assert_text "Pending"

    accept_confirm { click_button "Run audit expiry now" }
    assert_text "Audit expiry queued."
    assert_selector "h2", text: "Audit expiry"
  end

  test "owner confirms a verified round trip and sees the retained target" do
    original = ENV["NAVISHAI_SOURCE_COMMIT"]
    ENV["NAVISHAI_SOURCE_COMMIT"] = "d" * 40
    workspaces(:acme_support).create_workspace_data_policy!
    sign_in
    click_link "Acme Support"
    click_link "Data & retention"

    button = find_button("Verify backup and restore")
    accept_confirm { button.send_keys(:enter) }

    assert_text "Archive round trip passed.", wait: 12
    assert_text "new verification target Workspace"
    assert_text "Passed: Round trip verified"
    assert_no_text "engine-private"

    page.current_window.resize_to(320, 844)
    assert_operator page.evaluate_script("document.documentElement.scrollWidth - window.innerWidth"), :<=, 0
    assert_operator find_button("Verify backup and restore").evaluate_script("this.getBoundingClientRect().height"), :>=, 48
  ensure
    original ? ENV["NAVISHAI_SOURCE_COMMIT"] = original : ENV.delete("NAVISHAI_SOURCE_COMMIT")
  end

  private
    def sign_in
      visit new_session_path
      fill_in "Email address", with: users(:owner).email_address
      fill_in "Password", with: "password12345"
      click_button "Sign in"
    end
end
