require "test_helper"

class IntercomHelpCenterSyncTest < ActiveSupport::TestCase
  class Client
    attr_accessor :pages, :articles_by_id, :fail_cursor
    def initialize(article)
      @pages = { nil => { "data" => [ article ], "pages" => {} } }
      @articles_by_id = { article.fetch("id") => article }
    end
    def articles(starting_after:)
      raise IntercomClient::Unavailable if fail_cursor && starting_after == fail_cursor
      pages.fetch(starting_after)
    end
    def article(id)
      articles_by_id.fetch(id) { raise IntercomClient::NotFound }
    end
  end

  setup do
    @workspace = workspaces(:acme_support)
    @connection = @workspace.intercom_connections.create!(name: "Docs", remote_workspace_id: "docs", credential_key: "docs", help_center_sync_enabled: true)
    @article = { "id" => "article1", "title" => "Recovery", "body" => "<p>Recovery steps</p>", "state" => "published", "updated_at" => 1.day.ago.to_i, "url" => "https://docs.example.com/recovery" }
    @client = Client.new(@article)
  end

  test "sync preserves versions, origin, titles, and independent connections" do
    run_sync
    source = @connection.knowledge_sources.sole
    original = source.current_version
    run_sync
    assert_equal 1, source.versions.count
    @article["title"] = "Account recovery"
    run_sync
    assert_equal 2, source.versions.count
    assert_equal "Account recovery", source.reload.display_title
    assert_equal "Recovery", original.reload.source_title
    assert_equal @article["url"], source.current_version.retrieved_from_url
    other = @workspace.intercom_connections.create!(name: "Other", remote_workspace_id: "other", credential_key: "other", help_center_sync_enabled: true)
    IntercomHelpCenterSync.sync!(connection: other, client: @client)
    assert_equal 2, @workspace.knowledge_sources.where(external_id: "article1").count
  end

  test "unchanged sync refreshes current evidence without refreshing historical versions" do
    run_sync
    source = @connection.knowledge_sources.sole
    original = source.current_version
    travel 40.days do
      run_sync
      resolver = CrewEvidenceResolver.new(workspace: @workspace, task: Struct.new(:support_case).new(nil), run: nil)
      assert resolver.resolve(kind: "knowledge", locator: original.citation_uri, freshness_days: 30).available?
      assert_equal 1, source.versions.count
      @article["body"] = "<p>Updated recovery steps</p>"
      run_sync
      assert_equal "stale", resolver.resolve(kind: "knowledge", locator: original.citation_uri, freshness_days: 30).snapshot.fetch("status")
      assert resolver.resolve(kind: "knowledge", locator: source.reload.current_version.citation_uri, freshness_days: 30).available?
    end
  end

  test "absence requires complete passes and republishing restores history" do
    run_sync
    source = @connection.knowledge_sources.sole
    @client.pages[nil]["data"] = []
    @client.articles_by_id = {}
    run_sync
    assert source.reload.stale?
    assert_not source.deleted?
    run_sync
    assert source.reload.deleted?
    assert_empty KnowledgeSearch.search(workspace: @workspace, query: "Recovery")
    @client.pages[nil]["data"] = [ @article ]
    run_sync
    assert_not source.reload.deleted?
    assert_not source.stale?
    assert_equal 1, source.versions.count
  end

  test "failure resumes at the committed cursor without retiring absent content" do
    @client.pages[nil]["pages"] = { "next" => { "starting_after" => "second" } }
    @client.pages["second"] = { "data" => [], "pages" => {} }
    @client.fail_cursor = "second"
    assert_raises(IntercomHelpCenterSync::Error) { run_sync }
    pass = @connection.knowledge_sync_passes.sole
    assert_equal "second", pass.cursor
    assert_equal 1, pass.page_count
    assert_equal "failed", pass.status
    @client.fail_cursor = nil
    run_sync
    assert_equal "completed", pass.reload.status
    assert_equal 1, @connection.knowledge_sources.sole.versions.count
  end

  test "partial page bound never reconciles and disabled connection never calls API" do
    @client.pages[nil]["pages"] = { "next" => { "starting_after" => "second" } }
    pass = IntercomHelpCenterSync.sync!(connection: @connection, client: @client, max_pages: 1)
    assert_nil pass.completed_at
    @connection.update!(help_center_sync_enabled: false)
    assert_nil run_sync
  end

  test "oversized malformed and repeated cursor responses stop without a checkpoint" do
    @article["body"] = "x" * (KnowledgeSourceVersion::MAX_CONTENT_BYTES + 1)
    assert_equal "article_too_large", assert_raises(IntercomHelpCenterSync::Error) { run_sync }.code
    assert_equal 0, @connection.knowledge_sync_passes.sole.page_count
    assert_empty @connection.knowledge_sources
    @article["body"] = "ok"
    @article["state"] = "unknown"
    assert_equal "malformed_article", assert_raises(IntercomHelpCenterSync::Error) { run_sync }.code
  end

  test "manual sources and other Workspaces cannot be retired" do
    manual = KnowledgeIngestion.ingest_integration!(workspace: @workspace, source_kind: :intercom_help_center, external_id: "manual", title: "Manual", content: "Approved", source_updated_at: Time.current)
    2.times { run_sync }
    assert_not manual.reload.deleted?
    assert_nil manual.knowledge_sync_observation
  end

  private
    def run_sync
      IntercomHelpCenterSync.sync!(connection: @connection, client: @client)
    end
end
