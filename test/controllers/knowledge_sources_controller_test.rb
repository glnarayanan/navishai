require "test_helper"

class KnowledgeSourcesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @workspace = workspaces(:acme_support)
    @owner = memberships(:owner_support)
    @source = KnowledgeIngestion.create!(
      workspace: @workspace, membership: @owner,
      source_kind: :manual, title: "Account access", content: "Use the owner recovery link."
    )
  end

  test "members can search and inspect current version citations" do
    member = @workspace.memberships.create!(
      user: User.create!(email_address: "knowledge-member@example.com", password: "password12345", verified_at: Time.current),
      role: :member
    )
    sign_in_as member.user

    get workspace_knowledge_sources_path(@workspace), params: { q: "recovery" }

    assert_response :success
    assert_select "h1", "Knowledge sources"
    assert_select ".knowledge-results a", "Account access"
    assert_select ".citation-uri", @source.current_version.citation_uri
    assert_select "#add-source-title", count: 0

    get workspace_knowledge_source_path(@workspace, @source)
    assert_response :success
    assert_select "h1", "Account access"
    assert_select "#new-version-title", count: 0
  end

  test "a manager creates, versions, and deletes a source with durable history" do
    manager = @workspace.memberships.create!(
      user: User.create!(email_address: "knowledge-manager@example.com", password: "password12345", verified_at: Time.current),
      role: :manager
    )
    sign_in_as manager.user

    assert_difference [ "KnowledgeSource.count", "KnowledgeSourceVersion.count" ], 1 do
      post workspace_knowledge_sources_path(@workspace), params: {
        knowledge_source: {
          source_kind: "url", title: "Billing policy", url: "https://docs.example.com/billing",
          content: "Invoices are due in thirty days."
        }
      }
    end
    source = @workspace.knowledge_sources.find_by!(title: "Billing policy")
    assert_redirected_to workspace_knowledge_source_path(@workspace, source)

    assert_difference "KnowledgeSourceVersion.count", 1 do
      patch workspace_knowledge_source_path(@workspace, source), params: {
        knowledge_source: { content: "Invoices are due in forty-five days." }
      }
    end
    assert_equal 2, source.reload.current_version.version_number

    assert_no_difference "KnowledgeSourceVersion.count" do
      delete workspace_knowledge_source_path(@workspace, source)
    end
    assert source.reload.deleted?

    get workspace_knowledge_source_path(@workspace, source)
    assert_select ".knowledge-warning", text: /Deleted from current use/
    assert_select ".knowledge-version-list li", count: 2
  end

  test "invalid content rerenders while viewer writes and foreign source paths fail closed" do
    sign_in_as users(:owner)
    assert_no_difference [ "KnowledgeSource.count", "AuditEvent.count" ] do
      post workspace_knowledge_sources_path(@workspace), params: {
        knowledge_source: { source_kind: "url", title: "Unsafe", url: "http://127.0.0.1/private", content: "Text" }
      }
    end
    assert_response :unprocessable_content
    assert_select ".inline-error", text: /public HTTPS URL/

    assert_no_difference [ "KnowledgeSource.count", "AuditEvent.count" ] do
      post workspace_knowledge_sources_path(@workspace), params: {
        knowledge_source: { source_kind: "url", title: "Private", url: "https://127.0.0.1/private", content: "Text" }
      }
    end
    assert_response :unprocessable_content

    sign_out
    viewer = @workspace.memberships.create!(
      user: User.create!(email_address: "knowledge-controller-viewer@example.com", password: "password12345", verified_at: Time.current),
      role: :viewer
    )
    sign_in_as viewer.user
    post workspace_knowledge_sources_path(@workspace), params: {
      knowledge_source: { source_kind: "manual", title: "Denied", content: "Denied" }
    }
    assert_response :forbidden

    sign_out
    sign_in_as users(:owner)
    get workspace_knowledge_source_path(workspaces(:beta_support), @source)
    assert_response :not_found
  end
end
