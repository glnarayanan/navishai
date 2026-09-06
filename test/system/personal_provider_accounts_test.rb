require "application_system_test_case"

class PersonalProviderAccountsTest < ApplicationSystemTestCase
  setup do
    @workspace = workspaces(:acme_support)
    @original_forgery_protection = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    @catalog = [ { "adapter_key" => "codex_subscription", "configured" => true,
      "auth_mode" => "subscription", "execution_mode" => "strong_isolated" } ]
    @result = { "state" => "pending", "challenge" => {
      "verification_url" => "https://auth.openai.com/codex/device", "user_code" => "ABCD-1234", "login_id" => "fixture" } }
    @original_provider = ProviderConnectionGateway.method(:new)
    @original_personal = PersonalProviderGateway.method(:new)
    owner = self
    provider = Object.new
    provider.define_singleton_method(:catalog) { |**| owner.instance_variable_get(:@catalog) }
    gateway = Object.new
    gateway.define_singleton_method(:account) do |action:, **|
      error = owner.instance_variable_get(:@operation_errors)&.fetch(action, nil)
      raise error if error
      action == "disconnect" ? { "state" => "disconnected" } : owner.instance_variable_get(:@result)
    end
    ProviderConnectionGateway.define_singleton_method(:new) { provider }
    PersonalProviderGateway.define_singleton_method(:new) { gateway }
  end

  teardown do
    ProviderConnectionGateway.define_singleton_method(:new, @original_provider)
    PersonalProviderGateway.define_singleton_method(:new, @original_personal)
    ActionController::Base.allow_forgery_protection = @original_forgery_protection
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
  end

  test "disabled provider cannot start and device sign-in supports refresh failure and disconnect" do
    sign_in users(:owner)
    visit workspace_personal_provider_accounts_path(@workspace)
    assert_text "No personal accounts connected"
    @catalog = []
    click_button "Connect Codex"
    assert_text "An Admin must enable server-side Codex subscription access first."
    assert_equal 0, PersonalProviderAccount.where(workspace: @workspace).count
    @catalog = [ { "adapter_key" => "codex_subscription", "configured" => true,
      "auth_mode" => "subscription", "execution_mode" => "strong_isolated" } ]
    click_button "Connect Codex"
    assert_text "ABCD-1234"
    assert_selector "a[target='_blank'][rel='noopener noreferrer']", text: "Open Codex sign-in"
    assert_no_horizontal_overflow
    assert_no_csp_violations
    save_screenshot Rails.root.join("tmp/personal-provider-desktop.png")
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: 320, height: 844, deviceScaleFactor: 1, mobile: false)
    assert_equal 320, page.evaluate_script("window.innerWidth")
    assert_no_horizontal_overflow
    find_link("Open Codex sign-in").send_keys(:tab)
    assert_selector "button:focus", text: "Check sign-in"
    save_screenshot Rails.root.join("tmp/personal-provider-mobile.png")
    @result = { "state" => "pending" }
    click_button "Check sign-in"
    assert_text "The server is preparing or checking your sign-in."
    @result = { "state" => "failed" }
    click_button "Check sign-in"
    assert_text "Sign-in or the connection test failed."
    click_button "Disconnect my account"
    assert_text "Your AI account was disconnected."
    assert_equal "disconnected", PersonalProviderAccount.where(workspace: @workspace).sole.state
  end
  test "connected account awaits approval and only its owner can select it for work" do
    owner = memberships(:owner_support)
    account = PersonalProviderAccount.create!(workspace: @workspace, membership: owner)
    report = runtime_installations(:acme_scripted).attributes.slice(*RunnerProtocol::RuntimeDetectionResponse::INSTALLATION_KEYS)
    report.merge!("adapter_key" => "codex_subscription", "transport" => "managed_process",
      "execution_mode" => "strong_isolated", "detection_key" => "c" * 64)
    @result = { "state" => "connected", "installation" => report,
      "runtime_test" => { "tested_at" => Time.current, "input_units" => 1, "output_units" => 1, "usage_observed" => true } }
    sign_in users(:owner)
    visit workspace_personal_provider_account_path(@workspace, account)
    assert_text "An Admin must approve this account"
    assert_not account.reload.usable?
    save_screenshot Rails.root.join("tmp/personal-provider-awaiting-approval.png")
    installation = account.runtime_installation
    installation.update!(approved: true, approved_by_membership: owner, approved_by_user: owner.user, approved_at: Time.current)
    visit workspace_personal_provider_account_path(@workspace, account)
    assert_text "Your account is ready."
    CrewConfiguration.install_defaults!(workspace: @workspace)
    support_case = create_support_case
    profile = @workspace.agent_profiles.find_by!(role_key: "support_investigator")
    task = CrewWork.create!(workspace: @workspace, membership: owner, scope: support_case, profile:,
      title: "Investigate account access", input_context: "Use the case.", expected_output: "Cite the evidence.")
    CrewWork.apply!(workspace: @workspace, membership: owner, task:, command: :start,
      expected_sequence: task.current_event.sequence_number)
    visit workspace_support_case_crew_task_path(@workspace, support_case, task)
    account_select = find_field("AI account")
    assert_equal "", account_select.value
    assert_selector "select option[value='#{account.id}']", text: "My Codex account"
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: 320, height: 844, deviceScaleFactor: 1, mobile: false)
    assert_no_horizontal_overflow
    capture_region Rails.root.join("tmp/personal-provider-run-choice-mobile.png"), from: "#task-execution-runs", through: "#task-execution-runs"
    @workspace.memberships.create!(user: users(:teammate), role: :member)
    open_workspace_nav
    click_button "Sign out"
    sign_in users(:teammate)
    visit workspace_personal_provider_accounts_path(@workspace)
    assert_text "No personal accounts connected"
    visit workspace_support_case_crew_task_path(@workspace, support_case, task)
    assert_no_field "AI account"
  end
  test "account forms work without Turbo with CSRF protection enabled" do
    account = PersonalProviderAccount.create!(workspace: @workspace, membership: memberships(:owner_support))
    sign_in users(:owner)
    visit workspace_personal_provider_account_path(@workspace, account)
    page.execute_script("document.querySelectorAll('form').forEach(form => form.dataset.turbo = 'false')")
    @result = { "state" => "failed" }
    click_button "Check sign-in"
    assert_text "Sign-in or the connection test failed."
    page.execute_script("document.querySelectorAll('form').forEach(form => form.dataset.turbo = 'false')")
    click_button "Disconnect my account"
    assert_text "Your AI account was disconnected."
  end
  test "a start that never reached the runner can be disconnected from the account list" do
    @operation_errors = { "start" => RunnerClient::Unavailable, "status" => RunnerClient::Conflict }
    sign_in users(:owner)
    visit workspace_personal_provider_accounts_path(@workspace)
    click_button "Connect Codex"
    assert_text "The provider service could not confirm the operation."
    account = PersonalProviderAccount.where(workspace: @workspace).sole
    assert account.starting?
    click_link "Check account"
    assert_current_path workspace_personal_provider_accounts_path(@workspace)
    assert_text "The provider service could not confirm the operation."
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: 320, height: 844, deviceScaleFactor: 1, mobile: false)
    assert_no_horizontal_overflow
    save_screenshot Rails.root.join("tmp/personal-provider-orphan-mobile.png")
    click_button "Disconnect my account"
    assert_text "Your AI account was disconnected."
    assert account.reload.disconnected?
    assert_no_button "Disconnect my account"
  end
end
