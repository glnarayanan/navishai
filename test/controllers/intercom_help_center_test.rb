require "test_helper"

class IntercomHelpCenterTest < ActionDispatch::IntegrationTest
  include SessionTestHelper

  setup do
    @workspace = workspaces(:acme_support)
    @connection = @workspace.intercom_connections.create!(name: "Docs", remote_workspace_id: "docs", credential_key: "docs")
  end

  test "owner enables and queues dedicated sync" do
    sign_in_as users(:owner)
    patch help_center_workspace_intercom_connection_path(@workspace, @connection), params: { intercom_connection: { help_center_sync_enabled: "true" } }
    assert_redirected_to workspace_intercom_connections_path(@workspace)
    assert @connection.reload.help_center_sync_enabled?
    assert_enqueued_with(job: IntercomHelpCenterSyncJob, args: [ @connection.id ]) do
      post sync_help_center_workspace_intercom_connection_path(@workspace, @connection)
    end
  end

  test "member cannot change or trigger sync" do
    @workspace.memberships.create!(user: users(:teammate), role: :member)
    sign_in_as users(:teammate)
    patch help_center_workspace_intercom_connection_path(@workspace, @connection), params: { intercom_connection: { help_center_sync_enabled: "true" } }
    assert_response :forbidden
    post sync_help_center_workspace_intercom_connection_path(@workspace, @connection)
    assert_response :forbidden
    assert_not @connection.reload.help_center_sync_enabled?
  end

  test "other Workspace connection cannot be configured" do
    sign_in_as users(:owner)
    other = workspaces(:acme_success).intercom_connections.create!(name: "Other", remote_workspace_id: "other", credential_key: "other")
    patch help_center_workspace_intercom_connection_path(@workspace, other), params: { intercom_connection: { help_center_sync_enabled: "true" } }
    assert_response :not_found
  end
end
