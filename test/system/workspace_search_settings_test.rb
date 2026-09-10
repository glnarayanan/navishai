require "application_system_test_case"

class WorkspaceSearchSettingsTest < ApplicationSystemTestCase
  test "Admin chooses a provider at desktop and mobile sizes and retains it during an outage" do
    workspace = workspaces(:acme_support)
    workspace.memberships.create!(user: users(:teammate), role: :admin)
    client = Object.new
    client.define_singleton_method(:web_search_catalog!) do |**|
      { "provider_keys" => %w[searxng exa], "default_provider_key" => "searxng" }
    end
    with_runner_client(client) do
      sign_in users(:teammate)
      visit edit_workspace_search_settings_path(workspace)
      assert_selector "h1", text: "Public-web search"
      assert_no_horizontal_overflow
      page.save_screenshot(Rails.root.join("tmp/workspace-search-desktop.png"))
      select "exa", from: "Authorised provider"
      click_button "Save search provider"
      assert_text "Search provider saved."
      assert_equal "exa", workspace.reload.web_search_provider_key
      page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: 320, height: 900, deviceScaleFactor: 1, mobile: false)
      assert_equal 320, page.evaluate_script("window.innerWidth")
      assert_no_horizontal_overflow
      assert_no_csp_violations
      find("select").send_keys(:tab)
      assert_selector "input[type=submit]:focus"
      FileUtils.mkdir_p(Rails.root.join("tmp/screenshots"))
      page.save_screenshot(Rails.root.join("tmp/screenshots/workspace-search-mobile.png"))
    end
    client.define_singleton_method(:web_search_catalog!) { |**| raise RunnerClient::Unavailable }
    with_runner_client(client) do
      visit edit_workspace_search_settings_path(workspace)
      assert_text "Your saved choice has been preserved."
      assert_text "Saved choice: exa"
      assert_no_selector "select"
      assert_no_horizontal_overflow
      assert_equal "exa", workspace.reload.web_search_provider_key
    end
  end
  teardown do
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
  end

  private
    def with_runner_client(client)
      original = RunnerClient.method(:new)
      RunnerClient.define_singleton_method(:new) { client }
      yield
    ensure
      RunnerClient.define_singleton_method(:new, original)
    end
end
