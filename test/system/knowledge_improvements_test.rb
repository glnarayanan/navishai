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

  test "adding a current version leaves the queue with retained version lineage" do
    workspace = workspaces(:acme_support)
    owner = memberships(:owner_support)
    KnowledgeIngestion.create!(
      workspace:, membership: owner,
      source_kind: :manual, title: "Follow-up recovery",
      content: "Legacy follow-up cancellation steps", expires_at: 1.minute.ago
    )
    sign_in(owner.user)
    page.current_window.resize_to(1440, 1000)
    visit workspace_knowledge_improvements_path(workspace)
    click_link "Follow-up recovery"
    fill_in "Approved source text", with: "Use the new follow-up recovery link."
    click_button "Add version"

    assert_text "Knowledge version added."
    assert_text "This source left the improvement queue"
    assert_selector ".knowledge-version-list li", count: 2

    visit workspace_knowledge_improvements_path(workspace)
    assert_selector "[data-metric=attention] strong", text: "0"
    assert_selector "[data-metric=improved] strong", text: "1"
    assert_text "Version 1 was stale. Version 2 is current."
    page.current_window.resize_to(320, 844)
    assert_no_horizontal_overflow
  end

  test "members create a candidate from a blocked draft and managers assign it" do
    workspace = workspaces(:acme_support)
    owner = memberships(:owner_support)
    support_case = create_support_case(subject: "Browser missing knowledge", workspace:, membership: owner)
    create_draft_artifact(
      workspace:, support_case:, membership: owner,
      body: "I cannot cite a current policy.", result_state: "blocked",
      blocker_message: "Applicable knowledge is missing."
    )
    sign_in(owner.user)
    page.current_window.resize_to(1440, 1000)
    visit workspace_support_quality_path(workspace)
    click_button "Create improvement candidate"
    assert_text "Knowledge improvement candidate recorded"

    visit workspace_knowledge_improvements_path(workspace)
    assert_selector "[data-metric=candidates] strong", text: "1"
    select owner.user.email_address, from: "Assign to"
    click_button "Assign"
    assert_text "Candidate assigned to a human who can maintain knowledge."
    assert_selector ".improvement-candidate", text: /Assigned/

    page.current_window.resize_to(320, 844)
    assert_no_horizontal_overflow
    assert_no_csp_violations
  end
end
