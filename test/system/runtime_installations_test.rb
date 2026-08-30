require "application_system_test_case"
require "digest"

class RuntimeInstallationsSystemTest < ApplicationSystemTestCase
  test "an Owner reviews and approves a runtime policy on desktop and mobile" do
    workspace = workspaces(:acme_support)
    installation = workspace.runtime_installations.create!(
      detection_key: "a" * 64, adapter_key: "fixture", protocol_version: "v1",
      executable_path: "/opt/navishai/fixture", executable_version: "fixture 2.4.1",
      account_metadata: { "authentication" => "managed_on_runner", "account_label" => "Fixture Team" },
      effective_model: "fixture-model", configuration_fingerprint: "c" * 64,
      capabilities: %w[structured_output tool_calling], minimum_version: "2.0.0", maximum_version: "2.x",
      compatibility_status: "compatible", incompatibility_reason: "", health_status: "available", checked_at: Time.current,
      runtime_test_status: "passed", runtime_tested_at: Time.current,
      runtime_tested_configuration_fingerprint: "c" * 64
    )
    untested = installation.dup
    untested.assign_attributes(
      detection_key: Digest::SHA256.hexdigest("untested-system-#{installation.id}"), approved: false, runtime_test_status: "untested",
      runtime_tested_at: nil, runtime_tested_configuration_fingerprint: nil
    )
    untested.save!
    original_limits = installation.slice(
      :max_timeout_seconds, :max_steps, :max_tool_calls, :max_input_units, :max_output_units
    )
    sign_in(users(:owner))
    visit workspace_runtime_installations_path(workspace)

    assert_text "AI providers"
    assert_text "Provider sign-in stays on your runner"
    assert_selector ".provider-setup", text: "/etc/navishai/execution.json", visible: :all
    assert_text "fixture-model"
    within "#runtime-#{untested.id}" do
      assert_field "Allow this provider in the workspace", disabled: true
      assert_text "Run a successful connection test before allowing access."
    end
    within "#runtime-#{installation.id}" do
      assert_button "Test again"
      find(".provider-advanced-settings > summary").click
      check "Allow this provider in the workspace"
      check "Support Crew · Investigator", exact: true
      check "Read cases"
      check "Case content"
      assert_no_field "Timeout cap (seconds)"
      assert_no_field "Step cap"
      assert_no_field "Input-unit cap"
      click_button "Save provider access"
    end

    assert_text "Provider access saved."
    assert_text "Approved"
    assert installation.reload.runnable?
    assert_equal %w[workspace_default], installation.profile_keys
    assert_equal original_limits, installation.slice(*original_limits.keys)
    within "#runtime-#{installation.id}" do
      find(".provider-advanced-settings > summary").click
    end
    if ENV["CAPTURE_RUNTIMES"]
      page.execute_script("arguments[0].scrollIntoView()", find("#runtime-#{installation.id} .runtime-policy-groups"))
      save_screenshot Rails.root.join(".amp/in/artifacts/runtime-approvals-desktop.png")
    end

    page.current_window.resize_to(320, 844)
    page.execute_script("arguments[0].scrollIntoView()", find("#runtime-#{installation.id} .runtime-policy-groups"))
    assert_equal 0, page.evaluate_script("Math.max(0, document.documentElement.scrollWidth - window.innerWidth)")
    open_workspace_nav
    runtimes_link = find_link("AI providers", match: :first)
    assert_operator runtimes_link.rect.width, :>=, 48
    assert_operator runtimes_link.rect.height, :>=, 48
    find("body").send_keys(:escape)
    within "#runtime-#{installation.id}" do
      assert_operator find_button("Save provider access").rect.height, :>=, 48
    end
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
