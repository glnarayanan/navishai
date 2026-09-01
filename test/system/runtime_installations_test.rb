require "application_system_test_case"
require "digest"

class RuntimeInstallationsSystemTest < ApplicationSystemTestCase
  test "saved provider settings show a truthful blocked test state on desktop and mobile" do
    workspace = workspaces(:acme_support)
    RuntimeInstallation.where(workspace:).delete_all
    catalog = [
      provider_payload(
        "codex_subscription", "Codex", %w[api_key subscription],
        "Run OpenAI Codex with a ChatGPT subscription or OpenAI API key."
      ).merge(
        "model_required" => false, "configured" => true, "auth_mode" => "subscription",
        "health_status" => "unavailable", "available" => false, "executable_version" => ""
      )
    ]
    gateway = Object.new
    gateway.define_singleton_method(:catalog) { |workspace_key:| catalog }
    original = ProviderConnectionGateway.method(:new)
    ProviderConnectionGateway.define_singleton_method(:new) { gateway }

    sign_in(users(:owner))
    visit workspace_runtime_installations_path(workspace)

    within "#runtime-codex_subscription" do
      assert_text "Settings saved"
      assert_text "Unavailable"
      assert_text "Provider default"
      assert_text "Codex will use its default model for now. You can enter an exact model ID in Edit settings."
      assert_button "Test connection", disabled: true
      assert_link "Edit settings"
      assert_no_text "Not selected"
    end
    assert_button "Refresh status"
    save_screenshot Rails.root.join(".amp/in/artifacts/provider-runtime-blocked-desktop.png") if ENV["CAPTURE_RUNTIMES"]

    page.current_window.resize_to(320, 844)
    assert_no_horizontal_overflow
    provider_card = find("#runtime-codex_subscription")
    within provider_card do
      assert_operator find_button("Test connection", disabled: true).rect.height, :>=, 48
      assert_operator find(".status-badge").rect.width, :<, provider_card.rect.width / 2
    end
    assert_operator find_button("Refresh status").rect.height, :>=, 48
    save_screenshot Rails.root.join(".amp/in/artifacts/provider-runtime-blocked-mobile.png") if ENV["CAPTURE_RUNTIMES"]
  ensure
    ProviderConnectionGateway.define_singleton_method(:new, original) if original
  end

  test "an Owner configures provider credentials in a responsive app form" do
    catalog = [
      provider_payload("codex", "Codex", %w[api_key subscription], "Use Codex for workspace tasks."),
      provider_payload("claude", "Claude", %w[subscription], "Use the runner's existing Claude sign-in.")
    ]
    gateway = Object.new
    gateway.define_singleton_method(:catalog) { |workspace_key:| catalog }
    original = ProviderConnectionGateway.method(:new)
    ProviderConnectionGateway.define_singleton_method(:new) { gateway }

    sign_in(users(:owner))
    visit new_workspace_provider_connection_path(workspaces(:acme_support))

    assert_selector "h1", text: "Add a provider"
    assert_select "Provider", selected: "Codex"
    assert_field "Sign-in method", with: "api_key"
    assert_field "Model ID (optional for now)"
    assert_field "API key", type: "password"
    select "Claude", from: "Provider"
    assert_field "Sign-in method", with: "subscription"
    assert_no_field "API key", visible: true
    select "Codex", from: "Provider"
    select "API key", from: "Sign-in method"
    fill_in "Model ID (optional for now)", with: "gpt-5.6"
    fill_in "API key", with: "one-time-provider-key"
    assert_button "Save and continue to test"
    assert_no_text "/etc/navishai"
    save_screenshot Rails.root.join(".amp/in/artifacts/provider-connection-desktop.png") if ENV["CAPTURE_RUNTIMES"]

    page.current_window.resize_to(320, 844)
    assert_no_horizontal_overflow
    assert_operator find_button("Save and continue to test").rect.height, :>=, 48
    save_screenshot Rails.root.join(".amp/in/artifacts/provider-connection-mobile.png") if ENV["CAPTURE_RUNTIMES"]
  ensure
    ProviderConnectionGateway.define_singleton_method(:new, original) if original
  end

  test "an Owner reviews and approves a runtime policy on desktop and mobile" do
    workspace = workspaces(:acme_support)
    installation = workspace.runtime_installations.create!(
      detection_key: "a" * 64, adapter_key: "fixture", protocol_version: "v1",
      transport: "built_in_https", execution_mode: "bounded",
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
    assert_text "API keys stay private"
    assert_link "Add provider"
    assert_no_text "/etc/navishai/execution.json"
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
      click_button "Save workspace access"
    end

    assert_text "Provider access saved."
    within "#runtime-#{installation.id}" do
      assert_text "Ready"
    end
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
      assert_operator find_button("Save workspace access").rect.height, :>=, 48
    end
    save_screenshot Rails.root.join(".amp/in/artifacts/runtime-approvals-mobile.png") if ENV["CAPTURE_RUNTIMES"]
  end

  private
    def provider_payload(adapter_key, name, auth_modes, description)
      {
        "adapter_key" => adapter_key, "name" => name, "description" => description,
        "auth_modes" => auth_modes, "model_required" => true, "configured" => false,
        "secret_configured" => false, "auth_mode" => "", "model" => "",
        "health_status" => "not_configured", "available" => true,
        "executable_version" => "#{adapter_key} 1.0.0"
      }
    end

    def sign_in(user)
      visit new_session_path
      fill_in "Email address", with: user.email_address
      fill_in "Password", with: "password12345"
      click_on "Sign in"
      assert_selector "h1", text: "Choose a workspace", wait: 6
    end
end
