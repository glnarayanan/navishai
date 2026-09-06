require "test_helper"

class IntegrationUserConnectionTest < ActiveSupport::TestCase
  setup do
    @workspace = workspaces(:acme_support)
    @membership = memberships(:owner_support)
    @connector = WorkspaceConnector.create!(workspace: @workspace, provider: "notion", enabled: true)
    @connection = IntegrationUserConnection.create!(workspace: @workspace, workspace_connector: @connector,
      membership: @membership, remote_user_id: "notion-user", remote_workspace_id: "notion-workspace",
      access_token: "private-access-token", refresh_token: "private-refresh-token")
  end

  test "credentials are encrypted at rest and only usable by their owning membership" do
    raw = IntegrationUserConnection.connection.select_one("SELECT access_token, refresh_token FROM integration_user_connections WHERE id = #{@connection.id}")
    refute_includes raw.fetch("access_token"), "private-access-token"
    refute_includes raw.fetch("refresh_token"), "private-refresh-token"
    assert_equal "private-access-token", @connection.access_token_for!(@membership)
    assert_raises(IntegrationOauth::Unavailable) { @connection.access_token_for!(memberships(:teammate_success)) }
  end

  test "disabled connector and expired authorization reject credential use" do
    @connector.update!(enabled: false)
    assert_raises(IntegrationOauth::Unavailable) { @connection.access_token_for!(@membership) }
    @connector.update!(enabled: true)
    @connection.update!(expires_at: 1.minute.ago)
    assert_raises(IntegrationOauth::Unavailable) { @connection.access_token_for!(@membership) }
  end

  test "connections cannot cross workspace boundaries" do
    @connection.membership = memberships(:teammate_success)
    assert_not @connection.valid?
    assert_includes @connection.errors[:workspace], "must match the connection and membership"
  end
end
