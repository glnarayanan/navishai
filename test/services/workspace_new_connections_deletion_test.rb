require "test_helper"

class WorkspaceNewConnectionsDeletionTest < ActiveSupport::TestCase
  setup do
    @workspace = workspaces(:acme_support)
    @owner = memberships(:owner_support)
    @account = PersonalProviderAccount.create!(workspace: @workspace, membership: @owner, state: "connected")
    @runtime = approve_scripted_runtime(workspace: @workspace, membership: @owner)
    @runtime.update!(personal_provider_account: @account)
    @connector = WorkspaceConnector.create!(workspace: @workspace, provider: "notion", enabled: true,
      service_token: "workspace-secret")
    @user_connection = IntegrationUserConnection.create!(workspace: @workspace, workspace_connector: @connector,
      membership: @owner, remote_user_id: "personal-user", remote_workspace_id: "personal-workspace",
      access_token: "personal-secret")
    @connection = NotionKnowledgeConnection.create!(workspace: @workspace, workspace_connector: @connector,
      name: "Handbook", root_page_ids: [ "11111111-1111-1111-1111-111111111111" ])
    @pass = KnowledgeSyncPass.create!(workspace: @workspace, notion_knowledge_connection: @connection)
    @records = [ @account, @runtime, @connector, @user_connection, @connection, @pass ]
    @request = WorkspaceDeletion.request!(workspace: @workspace, membership: @owner, confirmation: @workspace.slug)
  end

  test "purges personal credentials before deleting connector and sync records" do
    calls = []
    test = self
    records = @records
    workspace = @workspace
    personal_gateway = Object.new
    personal_gateway.define_singleton_method(:purge_workspace) do |workspace_key:|
      test.assert_equal [ workspace.runner_key ], calls
      test.assert_equal workspace.runner_key, workspace_key
      test.assert Workspace.exists?(workspace.id)
      records.each { |record| test.assert record.class.exists?(record.id) }
      calls << :personal_purged
      true
    end

    tombstone = WorkspaceDeletion.perform!(request: @request,
      provider_gateway: provider_purge_gateway(calls:), personal_gateway:)

    assert_not_nil tombstone
    assert_equal [ @workspace.runner_key, :personal_purged ], calls
    refute Workspace.exists?(@workspace.id)
    @records.each { |record| refute record.class.exists?(record.id), "retained #{record.class}" }
    assert User.exists?(@owner.user_id)
  end

  test "personal credential purge failure retains records until owner retries" do
    personal_gateway = Object.new
    personal_gateway.define_singleton_method(:purge_workspace) do |workspace_key:|
      raise RunnerClient::Unavailable, "personal credential store unavailable"
    end

    assert_nil WorkspaceDeletion.perform!(request: @request,
      provider_gateway: provider_purge_gateway, personal_gateway:)

    assert @request.reload.failed?
    assert_equal "unavailable", @request.failure_code
    assert @workspace.reload.deletion_requested?
    @records.each { |record| assert record.class.exists?(record.id), "lost #{record.class} before credential purge" }
    assert_equal "personal-secret", @user_connection.reload.access_token
    assert_equal "workspace-secret", @connector.reload.service_token
    assert_nil WorkspaceTombstone.find_by(former_workspace_id: @workspace.id)

    WorkspaceDeletion.retry!(workspace: @workspace, membership: @owner)
    calls = []
    tombstone = WorkspaceDeletion.perform!(request: @request,
      provider_gateway: provider_purge_gateway, personal_gateway: provider_purge_gateway(calls:))

    assert_not_nil tombstone
    assert_equal [ @workspace.runner_key ], calls
    refute Workspace.exists?(@workspace.id)
    @records.each { |record| refute record.class.exists?(record.id) }
  end
end
