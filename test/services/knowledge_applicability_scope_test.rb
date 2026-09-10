require "test_helper"

class KnowledgeApplicabilityScopeTest < ActiveSupport::TestCase
  setup do
    @workspace = workspaces(:acme_support)
    @owner = memberships(:owner_support)
    @product = @workspace.products.create!(name: "Billing")
    @other_product = @workspace.products.create!(name: "Support")
    @connection = @workspace.intercom_connections.create!(name: "First", remote_workspace_id: "first", credential_key: "first")
    @other_connection = @workspace.intercom_connections.create!(name: "Second", remote_workspace_id: "second", credential_key: "second")
    @case = create_support_case
    @case.support_case_products.create!(workspace: @workspace, product: @product)
    @case.create_intercom_conversation_link!(workspace: @workspace, intercom_connection: @connection,
      conversation: @case.conversation, remote_conversation_id: "1", remote_state: "open", source_digest: "a" * 64,
      remote_updated_at: Time.current, synced_at: Time.current)
    @source = KnowledgeIngestion.ingest_integration!(workspace: @workspace, source_kind: "intercom_help_center",
      title: "Recovery", content: "Recovery instructions.", external_id: "article", source_updated_at: Time.current,
      intercom_connection: @connection)
  end

  test "origin defaults limit Intercom knowledge and manual sources remain global" do
    manual = KnowledgeIngestion.create!(workspace: @workspace, membership: @owner,
      source_kind: "manual", title: "Recovery guide", content: "Recovery for everyone.")
    assert_equal [ @source.id, manual.id ].sort, search_ids.sort
    other_case = create_support_case(subject: "Native case")
    assert_equal [ manual.id ], KnowledgeSearch.search(workspace: @workspace, query: "recovery", support_case: other_case).map { |result| result.source.id }
    assert_equal 2, KnowledgeSearch.search(workspace: @workspace, query: "recovery").size
  end

  test "product and connection restrictions intersect and an override survives resync" do
    defaults = mapping(@connection, products: [ @other_product ], connections: [ @connection ])
    assert_empty search_ids
    override = mapping(@source, products: [ @product ], connections: [ @connection, @other_connection ])
    assert_equal [ @source.id ], search_ids
    defaults.knowledge_applicability_products.delete_all
    defaults.update!(all_products: true)
    KnowledgeIngestion.ingest_integration!(workspace: @workspace, source_kind: "intercom_help_center",
      title: "Recovery", content: "Recovery updated.", external_id: "article", source_updated_at: 1.minute.from_now,
      intercom_connection: @connection)
    assert_equal [ @product.id ], override.reload.product_ids
    assert_equal [ @source.id ], search_ids
    override.knowledge_applicability_connections.where(intercom_connection: @connection).delete_all
    assert_empty search_ids
  end

  test "unassigned cases inherit specific connection products but unknown context fails closed" do
    mapping(@source, products: [ @product ], connections: [ @connection ])
    @case.support_case_products.where(workspace: @workspace).delete_all
    assert_empty search_ids
    mapping(@connection, products: [ @product ], connections: [ @connection ])
    assert_equal [ @source.id ], search_ids
    foreign = create_support_case(workspace: workspaces(:beta_support), contact: contacts(:bob), membership: memberships(:outsider_beta))
    assert_raises(ArgumentError) { KnowledgeApplicabilityScope.new(workspace: @workspace, support_case: foreign) }
  end

  test "database rejects cross-workspace applicability and case products" do
    foreign_product = workspaces(:beta_support).products.create!(name: "Foreign")
    applicability = mapping(@source, products: [ @product ], connections: [ @connection ])
    assert_raises ActiveRecord::InvalidForeignKey do
      KnowledgeApplicabilityProduct.transaction(requires_new: true) do
        applicability.knowledge_applicability_products.create!(workspace: @workspace, product: foreign_product)
      end
    end
    assert_raises ActiveRecord::InvalidForeignKey do
      SupportCaseProduct.transaction(requires_new: true) do
        @case.support_case_products.create!(workspace: @workspace, product: foreign_product)
      end
    end
  end

  test "evidence admission rejects an inapplicable citation even when its locator is known" do
    task = Struct.new(:support_case).new(@case)
    resolver = CrewEvidenceResolver.new(workspace: @workspace, task:, run: nil)
    assert resolver.resolve(kind: "knowledge", locator: @source.citation_uri, freshness_days: 30).available?
    mapping(@source, products: [ @other_product ], connections: [ @connection ])
    assert_equal "unavailable", resolver.resolve(kind: "knowledge", locator: @source.citation_uri, freshness_days: 30).snapshot.fetch("status")
  end

  private
    def mapping(owner, products:, connections:)
      owner.create_knowledge_applicability!(workspace: @workspace, all_products: false, all_connections: false).tap do |mapping|
        products.each { |product| mapping.knowledge_applicability_products.create!(workspace: @workspace, product:) }
        connections.each { |intercom_connection| mapping.knowledge_applicability_connections.create!(workspace: @workspace, intercom_connection:) }
      end
    end

    def search_ids
      KnowledgeSearch.search(workspace: @workspace, query: "recovery", support_case: @case.reload).map { |result| result.source.id }
    end
end
