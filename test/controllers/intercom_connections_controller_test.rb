require "test_helper"

class IntercomConnectionsControllerTest < ActionDispatch::IntegrationTest
  include SessionTestHelper

  setup do
    @workspace = workspaces(:acme_support)
    sign_in_as(users(:owner))
    @connection = @workspace.intercom_connections.create!(
      name: "Historical", remote_workspace_id: "historical", credential_key: "historical"
    )
  end

  test "owner configures a connection without storing secrets" do
    assert_difference "IntercomConnection.count", 1 do
      post workspace_intercom_connections_path(@workspace), params: {
        intercom_connection: { name: "Support", remote_workspace_id: "app_123", credential_key: "support" }
      }
    end
    assert_redirected_to workspace_intercom_connections_path(@workspace)
    connection = @workspace.intercom_connections.find_by!(remote_workspace_id: "app_123")
    assert_equal "support", connection.credential_key
    assert AuditEvent.where(action: "intercom.connection_created", subject_id: connection.id, actor: users(:owner)).exists?
  end

  test "member cannot manage connections" do
    sign_in_as(users(:teammate))

    get workspace_intercom_connections_path(workspaces(:acme_success))

    assert_response :forbidden
  end

  test "every backfill action requires a current integration admin" do
    member = User.create!(
      email_address: "backfill-member@example.com", password: "password12345", verified_at: Time.current
    )
    @workspace.memberships.create!(user: member, role: :member)
    sign_in_as(member)

    post backfill_preview_workspace_intercom_connection_path(@workspace, @connection)
    assert_response :forbidden
    post backfill_confirm_workspace_intercom_connection_path(
      @workspace, @connection, manifest_id: 0
    ), params: { source_digest: "0" * 64 }
    assert_response :forbidden
    post backfill_resume_workspace_intercom_connection_path(@workspace, @connection, run_id: 0)
    assert_response :forbidden
    post backfill_resolve_identity_workspace_intercom_connection_path(
      @workspace, @connection, exception_id: 0
    ), params: { target_id: 0 }
    assert_response :forbidden
  end

  test "backfill record IDs from another workspace fail closed" do
    other = workspaces(:beta_support).intercom_connections.create!(
      name: "Other history", remote_workspace_id: "other-history", credential_key: "other_history"
    )

    post backfill_preview_workspace_intercom_connection_path(@workspace, other)
    assert_response :not_found
    post backfill_confirm_workspace_intercom_connection_path(
      @workspace, @connection, manifest_id: other.id
    ), params: { source_digest: "0" * 64 }
    assert_response :not_found
    post backfill_resume_workspace_intercom_connection_path(@workspace, @connection, run_id: other.id)
    assert_response :not_found
    post backfill_resolve_identity_workspace_intercom_connection_path(
      @workspace, @connection, exception_id: other.id
    ), params: { target_id: other.id }
    assert_response :not_found
  end

  test "confirmation rejects a tampered manifest digest before any remote request" do
    digest = Digest::SHA256.hexdigest("manifest")
    manifest = @connection.intercom_backfill_manifests.create!(
      workspace: @workspace, created_by_membership: memberships(:owner_support), created_by_user: users(:owner),
      source_digest: digest, discovery_records: [], counts: { "conversations" => 0 },
      discovered_at: Time.current, expires_at: 30.minutes.from_now
    )

    post backfill_confirm_workspace_intercom_connection_path(
      @workspace, @connection, manifest_id: manifest.id
    ), params: { source_digest: "0" * 64 }

    assert_redirected_to workspace_intercom_connections_path(@workspace)
    assert_equal "The dry run digest does not match.", flash[:alert]
    assert_empty @workspace.intercom_backfill_runs
  end
end
