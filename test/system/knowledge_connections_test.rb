require "application_system_test_case"

class KnowledgeConnectionsTest < ApplicationSystemTestCase
  teardown do
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
  end

  test "owner enables Help Center sync and sees checkpoint failure and completion" do
    workspace = workspaces(:acme_support)
    connection = workspace.intercom_connections.create!(name: "Docs", remote_workspace_id: "docs", credential_key: "docs")
    sign_in users(:owner)
    visit workspace_intercom_connections_path(workspace)
    within "#help-center-#{connection.id}" do
      assert_text "Not synced yet."
      assert_no_button "Sync Help Center now"
      select "Enabled", from: "Help Center sync"
      click_button "Save sync settings"
    end
    assert_text "Help Center sync settings saved."
    within "#help-center-#{connection.id}" do
      click_button "Sync Help Center now"
    end
    assert_text "Help Center sync queued."
    pass = KnowledgeSyncPass.create!(workspace:, intercom_connection: connection, page_count: 2, status: "failed", failure_code: "rate_limited")
    visit workspace_intercom_connections_path(workspace)
    within "#help-center-#{connection.id}" do
      assert_text "Failed · 2 pages checked · Rate limited"
      assert_text "saved checkpoint"
    end
    assert_no_horizontal_overflow
    capture_region Rails.root.join("tmp/help-center-desktop.png"), from: "#help-center-#{connection.id}", through: "#help-center-#{connection.id}"
    visit current_url
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: 320, height: 844, deviceScaleFactor: 1, mobile: false)
    assert_equal 320, page.evaluate_script("window.innerWidth")
    assert_no_horizontal_overflow
    assert_no_csp_violations
    capture_region Rails.root.join("tmp/help-center-mobile.png"), from: "#help-center-#{connection.id}", through: "#help-center-#{connection.id}"
    pass.update!(status: "completed", completed_at: Time.current, failure_code: nil)
    visit workspace_intercom_connections_path(workspace)
    within "#help-center-#{connection.id}" do
      assert_text "Completed · 2 pages checked"
      assert_no_text "saved checkpoint"
    end
  end

  test "Workspace connector settings keep personal accounts separate and hide admin controls from members" do
    workspace = workspaces(:acme_support)
    sign_in users(:owner)
    visit workspace_workspace_connectors_path(workspace)
    within "section[aria-labelledby='notion-title']" do
      assert_text "Disabled by the Workspace Admin"
      assert_no_button "Connect my Notion account"
      check "Enable Notion"
      fill_in "Workspace service token", with: "test-workspace-secret"
      click_button "Save Notion settings"
    end
    assert_text "Connector settings saved."
    within "section[aria-labelledby='notion-title']" do
      assert_equal "", find_field("Workspace service token").value
      find("summary", text: "Add Notion pages").click
      fill_in "Source name", with: "Team handbook"
      fill_in "Root page IDs", with: "11111111-1111-1111-1111-111111111111"
      click_button "Add source"
    end
    assert_text "Notion knowledge source added."
    assert_text "Team handbook"
    assert_text "Your account"
    assert_no_horizontal_overflow
    capture_region Rails.root.join("tmp/connectors-desktop.png"), from: "section[aria-labelledby='notion-title']", through: "section[aria-labelledby='notion-title']"
    visit current_url
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: 320, height: 844, deviceScaleFactor: 1, mobile: false)
    assert_equal 320, page.evaluate_script("window.innerWidth")
    assert_no_horizontal_overflow
    assert_no_csp_violations
    within "section[aria-labelledby='notion-title']" do
      find("summary", text: "Add Notion pages").click
      find_field("Source name").send_keys(:tab)
      assert_selector "textarea:focus"
      assert_no_horizontal_overflow
    end
    capture_region Rails.root.join("tmp/connectors-mobile.png"), from: "section[aria-labelledby='notion-title']", through: "section[aria-labelledby='notion-title']"
    workspace.memberships.create!(user: users(:teammate), role: :member)
    open_workspace_nav
    click_button "Sign out"
    sign_in users(:teammate)
    visit workspace_workspace_connectors_path(workspace)
    assert_text "Enabled for this Workspace"
    assert_no_field "Workspace service token"
    assert_no_button "Save Notion settings"
    assert_no_text "Shared knowledge"
  end
end
