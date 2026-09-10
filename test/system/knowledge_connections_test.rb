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
end
