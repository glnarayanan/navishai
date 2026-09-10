require "test_helper"

class NotionKnowledgeSyncTest < ActiveSupport::TestCase
  ROOT = "11111111-1111-1111-1111-111111111111"
  CHILD = "22222222-2222-2222-2222-222222222222"

  setup do
    @workspace = workspaces(:acme_support)
    connector = WorkspaceConnector.create!(workspace: @workspace, provider: "notion", enabled: true, service_token: "workspace-token")
    @connection = NotionKnowledgeConnection.create!(workspace: @workspace, workspace_connector: connector, name: "Handbook", root_page_ids: [ ROOT ])
    @edited_at = 1.day.ago.iso8601
    @documents = { ROOT => document(ROOT) }
    documents = @documents
    @client = Object.new
    @client.define_singleton_method(:document) do |id|
      value = documents.fetch(id) { raise NotionKnowledgeClient::Missing, "notion_missing" }
      raise value if value.is_a?(Exception)
      value
    end
  end

  test "unchanged pages preserve versions and changed pages append history" do
    sync
    source = @connection.knowledge_sources.sole
    original = source.current_version
    sync
    assert_equal 1, source.versions.count
    @documents[ROOT][:text] = "Updated procedure"
    sync
    assert_equal 2, source.versions.count
    assert_includes original.reload.content, "Original procedure"
    assert_equal ROOT, source.external_id
  end

  test "partial traversal checkpoints before a failure and resumes without retiring sources" do
    @documents[ROOT][:children] = [ CHILD ]
    @documents[CHILD] = NotionKnowledgeClient::Error.new("notion_unavailable")
    assert_raises(NotionKnowledgeClient::Error) { sync }
    pass = @connection.knowledge_sync_passes.sole
    assert_equal [ CHILD ], pass.frontier
    assert_equal 1, pass.page_count
    assert_not @connection.knowledge_sources.sole.stale?
    @documents[CHILD] = document(CHILD)
    sync
    assert_equal "completed", pass.reload.status
    assert_equal 2, @connection.knowledge_sources.count
  end

  test "two complete absences retire a source and reappearance restores the same history" do
    sync
    source = @connection.knowledge_sources.sole
    @documents.clear
    sync
    assert source.reload.stale?
    assert_not source.deleted?
    sync
    assert source.reload.deleted?
    @documents[ROOT] = document(ROOT)
    sync
    assert_not source.reload.deleted?
    assert_not source.stale?
    assert_equal 1, source.versions.count
  end

  test "disabled connector never invokes the provider" do
    @connection.workspace_connector.update!(enabled: false)
    @documents[ROOT] = RuntimeError.new("must not request")
    assert_nil sync
    assert_empty @connection.knowledge_sync_passes
  end

  test "incomplete nested traversal never advances or reconciles an accessible root" do
    sync
    source = @connection.knowledge_sources.sole
    client = NotionKnowledgeClient.new(connection: @connection)
    metadata = @documents.fetch(ROOT).fetch(:metadata)
    client.define_singleton_method(:request) do |_method, path, **_options|
      case path
      when "/v1/pages/#{ROOT}" then metadata
      when "/v1/blocks/#{ROOT}/children"
        { "results" => [ { "id" => CHILD, "type" => "child_database", "child_database" => { "title" => "Private" } } ], "has_more" => false }
      else raise NotionKnowledgeClient::Missing, "notion_missing"
      end
    end
    2.times do
      assert_raises(NotionKnowledgeClient::Error) { NotionKnowledgeSync.sync!(connection: @connection, client:) }
      pass = @connection.knowledge_sync_passes.unfinished.sole
      assert_equal 0, pass.page_count
      assert_equal [ ROOT ], pass.frontier
      assert_equal 0, source.reload.knowledge_sync_observation.missing_passes
      assert_not source.deleted?
    end
  end

  private
    def sync
      NotionKnowledgeSync.sync!(connection: @connection, client: @client)
    end

    def document(id)
      { metadata: { "id" => id, "properties" => { "Name" => { "type" => "title", "title" => [ { "plain_text" => "Handbook" } ] } },
        "last_edited_time" => @edited_at, "url" => "https://www.notion.so/#{id.delete('-')}" },
        text: "Original procedure", children: [] }
    end
end
