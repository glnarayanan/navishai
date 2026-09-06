require "test_helper"

class NotionKnowledgeConnectionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @workspace = workspaces(:acme_support)
    @connector = WorkspaceConnector.create!(workspace: @workspace, provider: "notion", enabled: true, service_token: "workspace-token")
    sign_in_as(users(:owner))
  end

  test "admin creates bounded roots and queues explicit sync" do
    assert_difference "NotionKnowledgeConnection.count", 1 do
      post workspace_notion_knowledge_connections_path(@workspace), params: {
        notion_knowledge_connection: { name: "Handbook", root_page_ids: "11111111-1111-1111-1111-111111111111" }
      }
    end
    assert_redirected_to workspace_workspace_connectors_path(@workspace)
    connection = NotionKnowledgeConnection.find_by!(workspace: @workspace)
    assert_enqueued_with(job: NotionKnowledgeSyncJob, args: [ connection.id ]) do
      post sync_workspace_notion_knowledge_connection_path(@workspace, connection)
    end
  end

  test "invalid roots and members cannot create shared content sources" do
    assert_no_difference "NotionKnowledgeConnection.count" do
      post workspace_notion_knowledge_connections_path(@workspace), params: {
        notion_knowledge_connection: { name: "Handbook", root_page_ids: "https://attacker.example/page" }
      }
    end
    @workspace.memberships.create!(user: users(:teammate), role: "member")
    sign_in_as(users(:teammate))
    assert_no_difference "NotionKnowledgeConnection.count" do
      post workspace_notion_knowledge_connections_path(@workspace), params: {
        notion_knowledge_connection: { name: "Handbook", root_page_ids: "11111111-1111-1111-1111-111111111111" }
      }
    end
    assert_response :forbidden
  end

  test "disabled Workspace connector prevents shared source creation" do
    @connector.update!(enabled: false)
    assert_no_difference "NotionKnowledgeConnection.count" do
      post workspace_notion_knowledge_connections_path(@workspace), params: {
        notion_knowledge_connection: { name: "Handbook", root_page_ids: "11111111-1111-1111-1111-111111111111" }
      }
    end
    assert_response :not_found
  end
end
