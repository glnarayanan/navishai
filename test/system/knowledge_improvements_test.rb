require "application_system_test_case"

class KnowledgeImprovementsSystemTest < ApplicationSystemTestCase
  test "members open stale sources from the improvement queue on desktop and 320px" do
    workspace = workspaces(:acme_support)
    owner = memberships(:owner_support)
    KnowledgeIngestion.create!(
      workspace:, membership: owner,
      source_kind: :manual, title: "Expired browser recovery",
      content: "Legacy browser cancellation steps", expires_at: 1.minute.ago
    )
    sign_in(owner.user)

    page.current_window.resize_to(1440, 1000)
    visit workspace_knowledge_sources_path(workspace)
    click_link "Review sources that need attention"
    assert_selector "h1", text: "Knowledge improvements"
    assert_selector "[data-metric=stale] strong", text: "1"
    click_link "Expired browser recovery"
    assert_selector "h1", text: "Expired browser recovery"
    assert_text "Current version is stale"

    visit workspace_knowledge_improvements_path(workspace)
    page.current_window.resize_to(320, 844)
    assert_no_horizontal_overflow
    assert_no_csp_violations
    assert_selector "h1", text: "Knowledge improvements"
    assert_selector ".improvement-list a", text: "Expired browser recovery"
  end
end
