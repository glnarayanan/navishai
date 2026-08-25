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
    assert_select "h1", "Runtime approvals"
    assert_select "code", "/opt/navishai/fixture"
    assert_select ".runtime-policy-form", count: 0
    assert_select "form[action='#{detect_workspace_runtime_installations_path(@workspace)}']", count: 0

    patch workspace_runtime_installation_path(@workspace, @installation), params: {
      runtime_installation: approval_attributes
    }
    assert_response :forbidden
    post detect_workspace_runtime_installations_path(@workspace)
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
end
