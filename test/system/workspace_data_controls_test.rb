require "application_system_test_case"

class WorkspaceDataControlsTest < ApplicationSystemTestCase
  test "owner reviews and queues content expiry at desktop and mobile widths" do
    workspaces(:acme_support).create_workspace_data_policy!(content_retention_days: 30, audit_retention_days: 365)
    sign_in
    click_link "Acme Support"
    click_link "Data"

    assert_selector "h1", text: "Data controls"
    assert_text "No content expiry runs yet."
    assert_link "Download workspace export"
    reveal_setup "Workspace import"
    assert_selector "h2", text: "Workspace import"
    assert_field "New Workspace name"
    assert_field "New Workspace slug"
    assert_field "Compressed Workspace archive"
    reveal_setup "Delete Workspace"
    assert_selector "h2", text: "Delete Workspace"
    assert_field "Type support to confirm"

    page.current_window.resize_to(320, 844)
    assert_equal 320, page.evaluate_script("window.innerWidth")
    assert_operator page.evaluate_script("document.documentElement.scrollWidth - window.innerWidth"), :<=, 0
    assert_operator find_button("Run content expiry now").evaluate_script("this.getBoundingClientRect().height"), :>=, 48
    assert_operator find_button("Run audit expiry now").evaluate_script("this.getBoundingClientRect().height"), :>=, 48
    assert_operator find_link("Download workspace export").evaluate_script("this.getBoundingClientRect().height"), :>=, 48
    assert_operator find_button("Import as new Workspace").evaluate_script("this.getBoundingClientRect().height"), :>=, 48
    assert_operator find_button("Delete Workspace").evaluate_script("this.getBoundingClientRect().height"), :>=, 48
    open_workspace_nav
    assert_operator find_link("Data").evaluate_script("this.getBoundingClientRect().height"), :>=, 48
    find("body").send_keys(:escape)

    accept_confirm { click_button "Run content expiry now" }
    assert_text "Content expiry queued."
    assert_text "Pending"

    accept_confirm { click_button "Run audit expiry now" }
    assert_text "Audit expiry queued."
    assert_selector "h2", text: "Audit expiry"
  end

  private
    def sign_in
      visit new_session_path
      fill_in "Email address", with: users(:owner).email_address
      fill_in "Password", with: "password12345"
      click_button "Sign in"
    end
end
