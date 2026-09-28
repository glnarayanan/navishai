require "test_helper"

class KnowledgeImprovementsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @workspace = workspaces(:acme_support)
    @owner = memberships(:owner_support)
  end

  test "owner member and viewer can read the improvement queue and navigation" do
    KnowledgeIngestion.create!(
      workspace: @workspace, membership: @owner,
      source_kind: :manual, title: "Expired recovery", content: "Legacy cancellation steps",
      expires_at: 1.minute.ago
    )
    member = @workspace.memberships.create!(
      user: User.create!(email_address: "knowledge-queue-member@example.com", password: "password12345", verified_at: Time.current),
      role: :member
    )
    viewer = @workspace.memberships.create!(
      user: User.create!(email_address: "knowledge-queue-viewer@example.com", password: "password12345", verified_at: Time.current),
      role: :viewer
    )

    [ users(:owner), member.user, viewer.user ].each do |user|
      sign_in_as user
      get workspace_knowledge_improvements_path(@workspace)

      assert_response :success
      assert_select "h1", "Knowledge improvements"
      assert_select ".nav-label", "Improvements"
      assert_select ".improvement-list a", text: /Expired recovery/
      sign_out
    end

    sign_in_as users(:owner)
    get workspace_knowledge_sources_path(@workspace)
    assert_select "a", text: "Review sources that need attention"
  end

  test "foreign Workspace paths fail closed" do
    sign_in_as users(:owner)

    get workspace_knowledge_improvements_path(workspaces(:beta_support))

    assert_response :not_found
  end
end
