require "test_helper"

class WorkspaceConnectorsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @workspace = workspaces(:acme_support)
    sign_in_as(users(:owner))
    @connector = WorkspaceConnector.create!(workspace: @workspace, provider: "notion", enabled: true)
  end

  test "admin saves a Workspace token without reflecting it" do
    patch workspace_workspace_connector_path(@workspace, "notion"), params: {
      workspace_connector: { enabled: "1", service_token: "private-workspace-token" }
    }
    assert_redirected_to workspace_workspace_connectors_path(@workspace)
    assert_equal "private-workspace-token", @connector.reload.service_access_token
    get workspace_workspace_connectors_path(@workspace)
    assert_response :success
    refute_includes response.body, "private-workspace-token"
    assert_equal "no-store", response.headers["Cache-Control"]
  end

  test "member can see connections but cannot enable a connector or set Workspace tokens" do
    @workspace.memberships.create!(user: users(:teammate), role: "member")
    sign_in_as(users(:teammate))
    get workspace_workspace_connectors_path(@workspace)
    assert_response :success
    patch workspace_workspace_connector_path(@workspace, "notion"), params: {
      workspace_connector: { enabled: "0", service_token: "unauthorized" }
    }
    assert_response :forbidden
    assert @connector.reload.enabled?
    assert_nil @connector.service_token
  end

  test "disabled connector prevents initiating authorization" do
    @connector.update!(enabled: false)
    assert_no_difference "IntegrationOauthAttempt.count" do
      post connect_workspace_workspace_connector_path(@workspace, "notion")
    end
    assert_redirected_to workspace_workspace_connectors_path(@workspace)
  end

  test "disabled or invalid state callback never requests a token" do
    get callback_workspace_workspace_connector_path(@workspace, "notion"), params: { state: "invalid-state", code: "secret-code" }
    assert_redirected_to workspace_workspace_connectors_path(@workspace)
    assert_equal 0, IntegrationUserConnection.where(workspace: @workspace).count
  end

  test "disconnect only removes the current member's credential" do
    owner = IntegrationUserConnection.create!(workspace: @workspace, workspace_connector: @connector,
      membership: memberships(:owner_support), remote_user_id: "owner", remote_workspace_id: "remote", access_token: "owner-token")
    member = @workspace.memberships.create!(user: users(:teammate), role: "member")
    teammate = IntegrationUserConnection.create!(workspace: @workspace, workspace_connector: @connector,
      membership: member, remote_user_id: "teammate", remote_workspace_id: "remote", access_token: "teammate-token")
    delete disconnect_workspace_workspace_connector_path(@workspace, "notion")
    assert_redirected_to workspace_workspace_connectors_path(@workspace)
    assert_not IntegrationUserConnection.exists?(owner.id)
    assert IntegrationUserConnection.exists?(teammate.id)
  end
  test "global callback routes only the matching session to its Workspace" do
    state = IntegrationOauthAttempt.issue!(connector: @connector, membership: memberships(:owner_support), session: Current.session)
    get integration_oauth_callback_path("notion"), params: { state:, code: "private-code" }
    assert_redirected_to callback_workspace_workspace_connector_path(@workspace, "notion", state:, code: "private-code")
    sign_in_as(users(:owner))
    get integration_oauth_callback_path("notion"), params: { state:, code: "private-code" }
    assert_response :not_found
  end

  test "private browsing cannot use another member account or a disabled connector" do
    IntegrationUserConnection.create!(workspace: @workspace, workspace_connector: @connector,
      membership: memberships(:owner_support), remote_user_id: "owner", remote_workspace_id: "remote", access_token: "owner-token")
    @workspace.memberships.create!(user: users(:teammate), role: "member")
    sign_in_as(users(:teammate))
    get content_workspace_workspace_connector_path(@workspace, "notion")
    assert_response :not_found
    sign_in_as(users(:owner))
    @connector.update!(enabled: false)
    get content_workspace_workspace_connector_path(@workspace, "notion")
    assert_redirected_to workspace_workspace_connectors_path(@workspace)
  end
end
