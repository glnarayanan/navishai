require "test_helper"

class KnowledgeApplicabilitiesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @workspace = workspaces(:acme_support)
    @source = KnowledgeIngestion.create!(workspace: @workspace, membership: memberships(:owner_support),
      source_kind: "manual", title: "Recovery", content: "Recovery instructions.")
    @product = @workspace.products.create!(name: "Billing")
    @path = workspace_knowledge_source_knowledge_applicability_path(@workspace, @source)
    sign_in_as users(:owner)
  end

  test "owner saves and resets an audited mapping without rewriting content" do
    assert_no_difference "KnowledgeSourceVersion.count" do
      patch @path, params: { knowledge_applicability: { all_products: "0", all_connections: "1", product_ids: [ @product.id ] } }
    end
    assert_redirected_to workspace_knowledge_source_path(@workspace, @source)
    assert_equal [ @product.id ], @source.reload.knowledge_applicability.product_ids
    event = @workspace.audit_events.find_by!(action: "knowledge.applicability_updated")
    assert_equal "inherited", event.metadata.fetch("previous_mapping")
    assert_equal [ @product.id ], JSON.parse(event.metadata.fetch("mapping")).fetch("product_ids")
    get workspace_knowledge_source_path(@workspace, @source)
    assert_response :success
    assert_select "h2", "Knowledge applicability"
    delete @path
    assert_nil @source.reload.knowledge_applicability
  end

  test "unselected and foreign selections cannot silently broaden mapping" do
    patch @path, params: { knowledge_applicability: { all_products: "0", all_connections: "1", product_ids: [ "" ] } }
    assert_redirected_to workspace_knowledge_source_path(@workspace, @source)
    assert_nil @source.reload.knowledge_applicability
    foreign = workspaces(:beta_support).products.create!(name: "Foreign")
    patch @path, params: { knowledge_applicability: { all_products: "0", all_connections: "1", product_ids: [ foreign.id ] } }
    assert_response :not_found
    assert_nil @source.reload.knowledge_applicability
  end

  test "manager can map articles but cannot configure products or defaults" do
    manager = @workspace.memberships.create!(user: User.create!(email_address: "mapping-manager@example.com", password: "password12345", verified_at: Time.current), role: :manager)
    sign_out
    sign_in_as manager.user
    patch @path, params: { knowledge_applicability: { all_products: "1", all_connections: "1" } }
    assert_redirected_to workspace_knowledge_source_path(@workspace, @source)
    post workspace_products_path(@workspace), params: { product: { name: "Denied" } }
    assert_response :forbidden
    connection = @workspace.intercom_connections.create!(name: "First", remote_workspace_id: "first", credential_key: "first")
    patch workspace_intercom_connection_knowledge_applicability_path(@workspace, connection), params: { knowledge_applicability: { all_products: "1", all_connections: "1" } }
    assert_response :forbidden
    manager.update!(role: :member)
    patch @path, params: { knowledge_applicability: { all_products: "1", all_connections: "1" } }
    assert_response :forbidden
  end

  test "admin creates and renames a product and assigns a case" do
    post workspace_products_path(@workspace), params: { product: { name: "Reports" } }
    assert_redirected_to workspace_products_path(@workspace)
    product = @workspace.products.find_by!(name: "Reports")
    patch workspace_product_path(@workspace, product), params: { product: { name: "Analytics" } }
    assert_equal "Analytics", product.reload.name
    get workspace_products_path(@workspace)
    assert_response :success
    support_case = create_support_case
    patch workspace_support_case_product_mapping_path(@workspace, support_case), params: { support_case: { product_ids: [ product.id ] } }
    assert_redirected_to workspace_support_case_path(@workspace, support_case)
    assert_equal [ product.id ], support_case.reload.product_ids
  end
end
