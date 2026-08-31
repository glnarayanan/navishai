require "test_helper"

class RuntimeInstallationsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @workspace = workspaces(:acme_support)
    @installation = create_installation(@workspace)
  end

  test "members inspect runtime facts but cannot change or detect policy" do
    user = User.create!(email_address: "runtime-member@example.com", password: "password12345", verified_at: Time.current)
    @workspace.memberships.create!(user: user, role: :member)
    sign_in_as user

    get workspace_runtime_installations_path(@workspace)
    assert_response :success
    assert_select "h1", "AI providers"
    assert_select "code", { text: "/opt/navishai/fixture", count: 0 }
    assert_select ".runtime-policy-form", count: 0
    assert_select "form[action='#{detect_workspace_runtime_installations_path(@workspace)}']", count: 0

    patch workspace_runtime_installation_path(@workspace, @installation), params: {
      runtime_installation: approval_attributes
    }
    assert_response :forbidden
    post detect_workspace_runtime_installations_path(@workspace)
    assert_response :forbidden
    post test_workspace_runtime_installation_path(@workspace, @installation)
    assert_response :forbidden
  end

  test "an Owner detects and approves a bounded runtime policy" do
    sign_in_as users(:owner)
    client = Object.new
    client.define_singleton_method(:detect_runtimes!) { |workspace_key:| [] }

    original = RunnerClient.method(:new)
    RunnerClient.define_singleton_method(:new) { client }
    begin
      post detect_workspace_runtime_installations_path(@workspace)
    ensure
      RunnerClient.define_singleton_method(:new, original)
    end
    assert_redirected_to workspace_runtime_installations_path(@workspace)
    assert_equal "missing", @installation.reload.health_status

    @installation.update!(health_status: "available")
    mark_test_passed!(@installation)
    patch workspace_runtime_installation_path(@workspace, @installation), params: {
      runtime_installation: approval_attributes
    }
    assert_redirected_to workspace_runtime_installations_path(@workspace, anchor: "runtime-#{@installation.id}")
    assert @installation.reload.runnable?
    assert_equal [ "support_investigator" ], @installation.allowed_role_keys
  end

  test "foreign installation paths fail closed" do
    sign_in_as users(:owner)
    foreign = create_installation(workspaces(:beta_support), key: "b" * 64)

    patch workspace_runtime_installation_path(@workspace, foreign), params: {
      runtime_installation: approval_attributes
    }

    assert_response :not_found
  end

  test "a removed provider does not linger as a standalone connection" do
    sign_in_as users(:owner)
    gateway = Object.new
    gateway.define_singleton_method(:catalog) do |workspace_key:|
      [
        {
          "adapter_key" => "fixture", "name" => "Fixture", "description" => "Fixture provider",
          "auth_modes" => [ "api_key" ], "model_required" => true, "configured" => false,
          "secret_configured" => false, "auth_mode" => "", "model" => "", "health_status" => "not_configured",
          "available" => true, "executable_version" => "fixture 2.4.1"
        }
      ]
    end
    original = ProviderConnectionGateway.method(:new)
    ProviderConnectionGateway.define_singleton_method(:new) { gateway }

    get workspace_runtime_installations_path(@workspace)

    assert_response :success
    assert_select "#runtime-#{@installation.id}", count: 0
  ensure
    ProviderConnectionGateway.define_singleton_method(:new, original) if original
  end

  test "saved provider settings stay distinct from runtime and connection test state" do
    @installation.destroy!
    sign_in_as users(:owner)
    gateway = Object.new
    gateway.define_singleton_method(:catalog) do |workspace_key:|
      [
        {
          "adapter_key" => "codex_subscription", "name" => "Codex",
          "description" => "Run OpenAI Codex with a ChatGPT subscription or OpenAI API key.",
          "auth_modes" => %w[api_key subscription], "model_required" => false, "configured" => true,
          "secret_configured" => false, "auth_mode" => "subscription", "model" => "",
          "health_status" => "unavailable", "available" => false, "executable_version" => ""
        }
      ]
    end
    original = ProviderConnectionGateway.method(:new)
    ProviderConnectionGateway.define_singleton_method(:new) { gateway }

    get workspace_runtime_installations_path(@workspace)

    assert_response :success
    assert_select "#runtime-codex_subscription" do
      assert_select ".provider-settings-status", text: "Settings saved"
      assert_select ".status-badge", text: "Runtime unavailable"
      assert_select "dt", text: "Model"
      assert_select "dd", text: "Provider default"
      assert_select "button[disabled]", text: "Test connection"
      assert_select ".provider-action-note", text: /No compatible Codex runtime is available/
      assert_select "a", text: "Edit settings"
      assert_select "form.provider-remove-form[data-turbo-confirm=?]",
        "Remove Codex from this workspace? Its saved sign-in settings and workspace access will be removed. You will need to set it up again before using it."
    end
    assert_not_includes response.body, "Not selected"
    assert_includes response.body, "will use its default model for now"
    assert_not_includes response.body, "does not expose a model list"
  ensure
    ProviderConnectionGateway.define_singleton_method(:new, original) if original
  end

  test "a live available provider requires a current test before approval" do
    sign_in_as users(:owner)

    with_provider_catalog([ live_provider ]) do
      get workspace_runtime_installations_path(@workspace)
    end

    assert_response :success
    assert_select "#runtime-#{@installation.id} .status-badge", text: "Test required"
    assert_select "#runtime-#{@installation.id} .status-badge.status-warning", text: "Test required"
    assert_select "#runtime-#{@installation.id} .provider-actions button", text: "Test connection", count: 1
    assert_select "#runtime-#{@installation.id} .provider-actions form:first-of-type button.button-primary", text: "Test connection", count: 1
    assert_select "#runtime-#{@installation.id} .provider-actions a.button-secondary", text: "Edit settings", count: 1
    actions_html = css_select("#runtime-#{@installation.id} .provider-actions").sole.to_html
    assert_operator actions_html.index("Test connection"), :<, actions_html.index("Edit settings")
    assert_select "#runtime-#{@installation.id} .provider-actions button[disabled]", text: "Test connection", count: 0
    assert_select "#runtime-#{@installation.id} .runtime-approval-toggle input[type='checkbox'][disabled]", count: 1
    assert_select "#runtime-#{@installation.id} .runtime-policy-form input[type='submit'][disabled]", count: 0
    assert_select "#runtime-#{@installation.id} .runtime-approval-toggle input[aria-describedby='runtime-#{@installation.id}-approval-requirement']", count: 1
    assert_select "#runtime-#{@installation.id} .runtime-policy-note", text: /Run a successful connection test before allowing this provider in the workspace/
  end

  test "a current passing test without approval requires approval" do
    mark_test_passed!(@installation)
    sign_in_as users(:owner)

    with_provider_catalog([ live_provider ]) do
      get workspace_runtime_installations_path(@workspace)
    end

    assert_response :success
    assert_select "#runtime-#{@installation.id} .status-badge", text: "Approval required"
    assert_select "#runtime-#{@installation.id} .status-badge.status-warning", text: "Approval required"
    assert_select "#runtime-#{@installation.id} .provider-actions button", text: "Test again", count: 1
    assert_select "#runtime-#{@installation.id} .provider-actions form:first-of-type button.button-secondary", text: "Test again", count: 1
    assert_select "#runtime-#{@installation.id} .provider-actions button[disabled]", text: "Test connection", count: 0
    assert_select "#runtime-#{@installation.id} .runtime-approval-toggle input[type='checkbox'][disabled]", count: 0
    assert_select "#runtime-#{@installation.id} .runtime-policy-form input.button-primary[value='Save workspace access'][disabled]", count: 0
    assert_select "#runtime-#{@installation.id} .runtime-policy-note", count: 0
  end

  test "an approved provider with a current passing test is ready" do
    mark_test_passed!(@installation)
    @installation.update!(
      approved: true, approved_by_membership: memberships(:owner_support), approved_by_user: users(:owner),
      approved_at: Time.current
    )
    sign_in_as users(:owner)

    with_provider_catalog([ live_provider ]) do
      get workspace_runtime_installations_path(@workspace)
    end

    assert_response :success
    assert_select "#runtime-#{@installation.id} .status-badge", text: "Ready"
    assert_select "#runtime-#{@installation.id} .status-badge.status-success", text: "Ready"
    assert_select "#runtime-#{@installation.id} .provider-actions button", text: "Test again", count: 1
    assert_select "#runtime-#{@installation.id} .provider-actions form:first-of-type button.button-secondary", text: "Test again", count: 1
  end

  test "a failed current test is labeled test failed" do
    @installation.update!(
      runtime_test_status: "failed", runtime_test_failure_code: "provider_error", runtime_tested_at: Time.current,
      runtime_tested_configuration_fingerprint: @installation.configuration_fingerprint
    )
    sign_in_as users(:owner)

    with_provider_catalog([ live_provider ]) do
      get workspace_runtime_installations_path(@workspace)
    end

    assert_response :success
    assert_select "#runtime-#{@installation.id} .status-badge", text: "Test failed"
    assert_select "#runtime-#{@installation.id} .status-badge.status-danger", text: "Test failed"
    assert_select "#runtime-#{@installation.id} .provider-actions button", text: "Test again", count: 1
    assert_select "#runtime-#{@installation.id} .provider-actions form:first-of-type button.button-primary", text: "Test again", count: 1
    assert_select "#runtime-#{@installation.id} .runtime-approval-toggle input[type='checkbox'][disabled]", count: 1
  end

  test "live provider unavailability blocks stale runtime access" do
    mark_test_passed!(@installation)
    @installation.update!(
      approved: true, approved_by_membership: memberships(:owner_support), approved_by_user: users(:owner),
      approved_at: Time.current
    )
    sign_in_as users(:owner)

    with_provider_catalog([ live_provider.merge("available" => false, "health_status" => "unavailable") ]) do
      get workspace_runtime_installations_path(@workspace)
    end

    assert_response :success
    assert_select "#runtime-#{@installation.id} .status-badge", text: "Runtime unavailable"
    assert_select "#runtime-#{@installation.id} .status-badge.status-neutral", text: "Runtime unavailable"
    assert_select "#runtime-#{@installation.id} .provider-actions button[disabled]", text: "Test connection", count: 1
    assert_select "#runtime-#{@installation.id} .runtime-approval-toggle input[type='checkbox'][name='runtime_installation[approved]'][disabled]", count: 1
    assert_select "#runtime-#{@installation.id} .runtime-policy-form input[type='hidden'][name='runtime_installation[approved]'][value='1']", count: 1
    assert_select "#runtime-#{@installation.id} .runtime-policy-form input[type='hidden'][name='runtime_installation[approved]'][value='0']", count: 0
    assert_select "#runtime-#{@installation.id} .provider-action-note", text: /Live Fixture settings are unavailable/
    assert_select "#runtime-#{@installation.id} .runtime-policy-form input[type='submit'][disabled]", count: 0
    assert_select "#runtime-#{@installation.id} .runtime-policy-note", text: /Live Fixture settings are unavailable.*allowing this provider in the workspace/
  end

  test "approved policy changes preserve approval when the disabled value is posted" do
    mark_test_passed!(@installation)
    @installation.update!(
      approved: true, approved_by_membership: memberships(:owner_support), approved_by_user: users(:owner),
      approved_at: Time.current
    )
    sign_in_as users(:owner)

    patch workspace_runtime_installation_path(@workspace, @installation), params: {
      runtime_installation: approval_attributes.merge(
        approved: "1", allowed_tools: %w[case_read knowledge_search],
        allowed_data_classes: %w[case_content customer_identity], max_steps: "12"
      )
    }

    assert_redirected_to workspace_runtime_installations_path(@workspace, anchor: "runtime-#{@installation.id}")
    installation = @installation.reload
    assert installation.approved?
    assert_equal %w[case_read knowledge_search], installation.allowed_tools
    assert_equal %w[case_content customer_identity], installation.allowed_data_classes
    assert_equal 12, installation.max_steps
  end

  test "catalog failure blocks stale standalone runtime access" do
    mark_test_passed!(@installation)
    @installation.update!(
      approved: true, approved_by_membership: memberships(:owner_support), approved_by_user: users(:owner),
      approved_at: Time.current
    )
    sign_in_as users(:owner)

    gateway = Object.new
    gateway.define_singleton_method(:catalog) do |workspace_key:|
      raise RunnerClient::Unavailable, "runner catalog endpoint timed out"
    end
    original = ProviderConnectionGateway.method(:new)
    ProviderConnectionGateway.define_singleton_method(:new) { gateway }

    get workspace_runtime_installations_path(@workspace)

    assert_response :success
    assert_select "#runtime-#{@installation.id} .status-badge", text: "Runtime unavailable"
    assert_select "#runtime-#{@installation.id} .provider-actions button[disabled]", text: "Test connection", count: 1
    assert_select "#runtime-#{@installation.id} .runtime-approval-toggle input[type='checkbox'][disabled]", count: 1
    assert_select "#runtime-#{@installation.id} .provider-action-note", text: /Live Fixture settings are unavailable/
    assert_not_includes response.body, "runner catalog endpoint timed out"
  ensure
    ProviderConnectionGateway.define_singleton_method(:new, original) if original
  end

  test "a successful catalog omission preserves standalone runtime behavior" do
    sign_in_as users(:owner)

    with_provider_catalog([ live_provider.merge("adapter_key" => "other", "name" => "Other") ]) do
      get workspace_runtime_installations_path(@workspace)
    end

    assert_response :success
    assert_select "#runtime-#{@installation.id} h2", text: "Fixture"
    assert_select "#runtime-#{@installation.id} .status-badge", text: "Test required"
    assert_select "#runtime-#{@installation.id} .provider-actions button", text: "Test connection", count: 1
    assert_select "#runtime-#{@installation.id} .provider-actions button[disabled]", text: "Test connection", count: 0
    assert_select "#runtime-#{@installation.id} .runtime-approval-toggle input[type='checkbox'][disabled]", count: 1
  end

  test "the provider page identifies missing runner configuration" do
    sign_in_as users(:owner)
    original = ProviderConnectionGateway.method(:new)
    ProviderConnectionGateway.define_singleton_method(:new) do
      raise RunnerClient::ClientConfigurationError, "runner shared secret must contain at least 32 bytes"
    end

    get workspace_runtime_installations_path(@workspace)

    assert_response :success
    assert_select "[role='alert']", text: "The provider service is not configured. Start the runner to manage provider connections."
    assert_not_includes response.body, "runner shared secret"
  ensure
    ProviderConnectionGateway.define_singleton_method(:new, original) if original
  end

  test "an Owner explicitly tests an installation and persists only safe evidence" do
    sign_in_as users(:owner)
    client = Object.new
    client.define_singleton_method(:test_runtime!) do |workspace_key:, request_id:, detection_key:, configuration_fingerprint:|
      {
        "protocol_version" => "v1", "workspace_key" => workspace_key, "request_id" => request_id,
        "detection_key" => detection_key, "configuration_fingerprint" => configuration_fingerprint,
        "effective_model" => "runtime_default", "status" => "passed", "failure_code" => nil,
        "usage_observed" => true, "input_units" => 8, "output_units" => 2,
        "tested_at" => "2026-08-31T12:00:00Z"
      }
    end
    original = RunnerClient.method(:new)
    RunnerClient.define_singleton_method(:new) { client }
    begin
      post test_workspace_runtime_installation_path(@workspace, @installation)
    ensure
      RunnerClient.define_singleton_method(:new, original)
    end

    assert_redirected_to workspace_runtime_installations_path(@workspace, anchor: "runtime-#{@installation.id}")
    assert_equal "Provider connection test passed.", flash[:notice]
    assert_equal "passed", @installation.reload.runtime_test_status
    assert_equal({ "status" => "passed" }, AuditEvent.order(:id).last.metadata)
  end

  test "a completed failed connection test redirects with an alert" do
    sign_in_as users(:owner)
    client = Object.new
    installation = @installation
    client.define_singleton_method(:test_runtime!) do |workspace_key:, request_id:, detection_key:, configuration_fingerprint:|
      {
        "protocol_version" => "v1", "workspace_key" => workspace_key, "request_id" => request_id,
        "detection_key" => detection_key, "configuration_fingerprint" => configuration_fingerprint,
        "effective_model" => installation.effective_model, "status" => "failed", "failure_code" => "provider_error",
        "usage_observed" => false, "input_units" => 0, "output_units" => 0,
        "tested_at" => "2026-08-31T12:00:00Z"
      }
    end
    original = RunnerClient.method(:new)
    RunnerClient.define_singleton_method(:new) { client }
    begin
      post test_workspace_runtime_installation_path(@workspace, @installation)
    ensure
      RunnerClient.define_singleton_method(:new, original)
    end

    assert_redirected_to workspace_runtime_installations_path(@workspace, anchor: "runtime-#{@installation.id}")
    assert_equal "Provider connection test failed. Check the credentials and model, then try again.", flash[:alert]
    assert_nil flash[:notice]
    assert_equal "failed", @installation.reload.runtime_test_status
  end

  test "runner failures render customer-facing copy without internal details" do
    sign_in_as users(:owner)
    client = Object.new
    client.define_singleton_method(:detect_runtimes!) do |workspace_key:|
      raise RunnerClient::Unavailable, "dial tcp 10.0.0.4:8081: connection refused"
    end
    client.define_singleton_method(:catalog) { |workspace_key:| [] }
    original = RunnerClient.method(:new)
    RunnerClient.define_singleton_method(:new) { client }

    post detect_workspace_runtime_installations_path(@workspace)

    assert_response :service_unavailable
    assert_select "[role='alert']", text: "The provider service is unavailable. Existing connections were not changed."
    assert_not_includes response.body, "10.0.0.4"
  ensure
    RunnerClient.define_singleton_method(:new, original) if original
  end

  private
    def create_installation(workspace, key: "a" * 64)
      workspace.runtime_installations.create!(
        detection_key: key, adapter_key: "fixture", protocol_version: "v1",
        executable_path: "/opt/navishai/fixture", executable_version: "fixture 2.4.1",
        account_metadata: { "authentication" => "managed_on_runner" },
        capabilities: %w[structured_output tool_calling], minimum_version: "2.0.0", maximum_version: "2.x",
        compatibility_status: "compatible", incompatibility_reason: "", health_status: "available",
        checked_at: Time.current
      )
    end

    def approval_attributes
      {
        approved: "1", allowed_role_keys: [ "support_investigator" ], allowed_tools: [ "case_read" ],
        allowed_data_classes: [ "case_content" ], profile_keys: [ "workspace_default" ],
        max_timeout_seconds: "300", max_steps: "10", max_tool_calls: "20",
        max_input_units: "100000", max_output_units: "25000"
      }
    end

    def mark_test_passed!(installation)
      installation.update!(
        runtime_test_status: "passed", runtime_tested_at: Time.current,
        runtime_tested_configuration_fingerprint: installation.configuration_fingerprint
      )
    end

    def live_provider
      {
        "adapter_key" => "fixture", "name" => "Fixture", "description" => "Fixture provider",
        "auth_modes" => [ "api_key" ], "model_required" => true, "configured" => true,
        "secret_configured" => true, "auth_mode" => "api_key", "model" => "fixture-model",
        "health_status" => "available", "available" => true, "executable_version" => "fixture 2.4.1"
      }
    end

    def with_provider_catalog(catalog)
      gateway = Object.new
      gateway.define_singleton_method(:catalog) { |workspace_key:| catalog }
      original = ProviderConnectionGateway.method(:new)
      ProviderConnectionGateway.define_singleton_method(:new) { gateway }
      yield
    ensure
      ProviderConnectionGateway.define_singleton_method(:new, original) if original
    end
end
