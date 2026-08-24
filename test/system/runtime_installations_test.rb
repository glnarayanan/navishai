require "application_system_test_case"

class RuntimeInstallationsSystemTest < ApplicationSystemTestCase
  test "an Owner reviews and approves a runtime policy on desktop and mobile" do
    workspace = workspaces(:acme_support)
    installation = workspace.runtime_installations.create!(
      detection_key: "a" * 64, adapter_key: "fixture", protocol_version: "v1",
      executable_path: "/opt/navishai/fixture", executable_version: "fixture 2.4.1",
      account_metadata: { "authentication" => "managed_on_runner", "account_label" => "Fixture Team" },
      capabilities: %w[structured_output tool_calling], minimum_version: "2.0.0", maximum_version: "2.x",
      compatibility_status: "compatible", incompatibility_reason: "", health_status: "available", checked_at: Time.current
    )
    sign_in(users(:owner))
    visit workspace_runtime_installations_path(workspace)

    assert_text "Runtime approvals"
    assert_text "Credentials stay on the runner"
    assert_text "/opt/navishai/fixture"
    check "Allow this runtime"
    check "Support Crew · Investigator", exact: true
    check "Read cases"
    check "Case content"
    fill_in "Timeout cap (seconds)", with: "420"
    click_button "Save runtime policy"

    assert_text "Runtime policy approved."
    assert_text "Approved"
    assert installation.reload.runnable?
    save_screenshot Rails.root.join(".amp/in/artifacts/runtime-approvals-desktop.png") if ENV["CAPTURE_RUNTIMES"]

    page.current_window.resize_to(320, 844)
    assert_equal 0, page.evaluate_script("Math.max(0, document.documentElement.scrollWidth - window.innerWidth)")
    runtimes_link = find_link("Runtimes", match: :first)
    assert_operator runtimes_link.rect.width, :>=, 48
    assert_operator runtimes_link.rect.height, :>=, 48
    assert_operator find_button("Save runtime policy").rect.height, :>=, 48
    save_screenshot Rails.root.join(".amp/in/artifacts/runtime-approvals-mobile.png") if ENV["CAPTURE_RUNTIMES"]
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
