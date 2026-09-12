require "test_helper"

class KnowledgeImprovementQueueTest < ActiveSupport::TestCase
  setup do
    @workspace = workspaces(:acme_support)
    @owner = memberships(:owner_support)
  end

  test "an empty library reports no attention" do
    queue = KnowledgeImprovementQueue.build(workspace: @workspace)

    assert_not queue.attention?
    assert_empty queue.items
    assert_empty queue.improved
    assert_equal 0, metric(queue, "attention").value
    assert_equal 0, metric(queue, "improved").value
  end

  test "lists expired, deleted, retired, and failed-sync sources and ignores current ones" do
    current = create_manual("Current access", "Use the current recovery link.")
    stale = create_manual("Expired access", "Legacy cancellation steps", expires_at: 1.minute.ago)
    deleted = create_manual("Deleted access", "Removed recovery steps")
    KnowledgeIngestion.new(workspace: @workspace, membership: @owner).delete!(knowledge_source: deleted)
    retired = ingest_article("retired-article", "Retired recovery")
    complete = complete_pass(retired.intercom_connection)
    retired.create_knowledge_sync_observation!(
      workspace: @workspace, last_seen_pass: complete, observed_at: 2.days.ago,
      missing_passes: 2, unavailable_at: 2.days.ago, retired_at: 1.day.ago
    )
    failed = ingest_article("failed-article", "Failed sync recovery")
    KnowledgeSyncPass.create!(
      workspace: @workspace, intercom_connection: failed.intercom_connection,
      status: "failed", failure_code: "rate_limited", page_count: 1
    )

    queue = KnowledgeImprovementQueue.build(workspace: @workspace)
    items = queue.items.index_by { |item| item.source.id }

    assert queue.attention?
    assert_nil items[current.id]
    assert_equal "stale", items.fetch(stale.id).reason
    assert_match(/expired/, items.fetch(stale.id).detail)
    assert_equal "deleted", items.fetch(deleted.id).reason
    assert_equal "retired", items.fetch(retired.id).reason
    assert_equal "failed_sync", items.fetch(failed.id).reason
    assert_equal 4, metric(queue, "attention").value
    assert_equal 1, metric(queue, "stale").value
    assert_equal 1, metric(queue, "deleted").value
    assert_equal 1, metric(queue, "retired").value
    assert_equal 1, metric(queue, "failed_sync").value
  end

  test "ignores foreign Workspace sources and failed syncs" do
    create_manual("Local expired", "Local expired steps", expires_at: 1.minute.ago)
    foreign = workspaces(:beta_support)
    foreign_manager = foreign.memberships.create!(
      user: User.create!(email_address: "foreign-knowledge-queue@example.com", password: "password12345", verified_at: Time.current),
      role: :manager
    )
    KnowledgeIngestion.create!(
      workspace: foreign, membership: foreign_manager,
      source_kind: :manual, title: "Foreign expired", content: "Foreign expired steps",
      expires_at: 1.minute.ago
    )

    queue = KnowledgeImprovementQueue.build(workspace: @workspace)

    assert_equal [ "Local expired" ], queue.items.map { |item| item.source.display_title }
    assert_empty queue.improved
  end

  test "a replacement current version leaves the queue and retains lineage" do
    source = create_manual("Expired access", "Legacy cancellation steps", expires_at: 1.minute.ago)
    prior = source.current_version
    assert KnowledgeImprovementQueue.build(workspace: @workspace).items.map(&:source).include?(source)

    KnowledgeIngestion.update!(
      workspace: @workspace, membership: @owner, knowledge_source: source,
      content: "Use the new recovery link from the account owner.", upload: nil, expires_at: nil
    )
    source.reload
    queue = KnowledgeImprovementQueue.build(workspace: @workspace)
    improved = queue.improved.sole

    assert_not queue.items.map(&:source).include?(source)
    assert source.left_improvement_queue?
    assert_equal source, improved.source
    assert_equal prior, improved.prior_version
    assert_equal source.current_version, improved.current_version
    assert_equal 2, source.versions.size
    assert prior.reload.stale?
    assert_not source.current_version.stale?
    assert_equal 1, metric(queue, "improved").value
    assert_equal 0, metric(queue, "attention").value
  end

  private
    def metric(queue, key)
      queue.counts.find { |item| item.key == key }
    end

    def create_manual(title, content, expires_at: nil)
      KnowledgeIngestion.create!(
        workspace: @workspace, membership: @owner,
        source_kind: :manual, title:, content:, expires_at:
      )
    end

    def ingest_article(external_id, title)
      connection = @workspace.intercom_connections.create!(
        name: "#{title} docs", remote_workspace_id: external_id, credential_key: external_id.tr("-", "_")
      )
      KnowledgeIngestion.ingest_integration!(
        workspace: @workspace, intercom_connection: connection, source_kind: :intercom_help_center,
        title:, content: "#{title} body", external_id:,
        source_updated_at: Time.current, retrieved_at: Time.current
      )
    end

    def complete_pass(connection)
      KnowledgeSyncPass.create!(
        workspace: @workspace, intercom_connection: connection,
        status: "completed", completed_at: Time.current, page_count: 1
      )
    end
end
