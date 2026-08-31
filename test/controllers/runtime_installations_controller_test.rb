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
    end
    assert_not_includes response.body, "Not selected"
  ensure
    ProviderConnectionGateway.define_singleton_method(:new, original) if original
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
end
