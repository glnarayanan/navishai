require "test_helper"

class IntercomConnectionsControllerTest < ActionDispatch::IntegrationTest
  include SessionTestHelper

  setup do
    @workspace = workspaces(:acme_support)
    sign_in_as(users(:owner))
  end

  test "owner configures a connection without storing secrets" do
    assert_difference "IntercomConnection.count", 1 do
      post workspace_intercom_connections_path(@workspace), params: {
        intercom_connection: { name: "Support", remote_workspace_id: "app_123", credential_key: "support" }
      }
    end
    assert_redirected_to workspace_intercom_connections_path(@workspace)
    connection = @workspace.intercom_connections.sole
    assert_equal "support", connection.credential_key
    assert AuditEvent.where(action: "intercom.connection_created", subject_id: connection.id, actor: users(:owner)).exists?
  end

  test "member cannot manage connections" do
    sign_in_as(users(:teammate))

    get workspace_intercom_connections_path(workspaces(:acme_success))

    assert_response :forbidden
  end
end
