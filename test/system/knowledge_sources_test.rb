require "application_system_test_case"

class KnowledgeSourcesTest < ApplicationSystemTestCase
  test "a manager maintains searchable versioned knowledge on desktop and mobile" do
    sign_in(users(:owner))
    visit workspace_support_cases_path(workspaces(:acme_support))
    click_on "Knowledge"

    assert_text "Knowledge sources"
    assert_no_field "HTTPS source URL"
    assert_no_field "Intercom article ID"
    select "Manual", from: "Source type"
    fill_in "Title", with: "Account recovery"
    fill_in "Approved source text", with: "Ask the account owner for the recovery code."
    click_button "Add knowledge source"

    assert_text "Knowledge source added."
    assert_text "Account recovery"
    assert_text "knowledge://sources/"
    fill_in "Approved source text", with: "Ask the account owner for the new recovery link."
    click_button "Add version"
    assert_text "Knowledge version added."
    assert_text "Version 2"
    assert_text "Version 1"

    click_link "Back to knowledge"
    fill_in "Search current knowledge", with: "recovery link"
    click_button "Search"
    within ".knowledge-results" do
      assert_text "Account recovery"
      assert_text "new recovery link"
    end

    page.current_window.resize_to(320, 844)
    assert_equal 0, page.evaluate_script("Math.max(0, document.documentElement.scrollWidth - window.innerWidth)")
    assert_operator find_field("Search current knowledge").rect.height, :>=, 48
    assert_operator find_button("Search").rect.height, :>=, 48
    open_workspace_nav
    knowledge_link = find_link("Knowledge", match: :first)
    assert_operator knowledge_link.rect.width, :>=, 48
    assert_operator knowledge_link.rect.height, :>=, 48
    find("body").send_keys(:escape)
    page.execute_script("window.scrollTo(0, 0)")
    save_screenshot Rails.root.join(".amp/in/artifacts/knowledge-sources-mobile.png") if ENV["CAPTURE_KNOWLEDGE"]

    page.current_window.resize_to(1440, 1000)
    save_screenshot Rails.root.join(".amp/in/artifacts/knowledge-sources-desktop.png") if ENV["CAPTURE_KNOWLEDGE"]
  end

  test "a viewer can inspect citations but cannot change knowledge" do
    workspace = workspaces(:acme_support)
    source = KnowledgeIngestion.create!(
      workspace:, membership: memberships(:owner_support),
      source_kind: :manual, title: "Read-only policy", content: "Current approved policy text."
    )
    viewer = User.create!(
      email_address: "knowledge-browser-viewer@example.com",
      password: "password12345", verified_at: Time.current
    )
    workspace.memberships.create!(user: viewer, role: :viewer)
    sign_in(viewer)

    visit workspace_knowledge_source_path(workspace, source)

    assert_text "Read-only policy"
    assert_text source.current_version.citation_uri
    assert_no_text "Add a checked version"
    assert_no_button "Delete knowledge source"
  end

  private
    def sign_in(user)
      visit new_session_path
      fill_in "Email address", with: user.email_address
      fill_in "Password", with: "password12345"
      click_on "Sign in"
      assert_selector "h1", text: "Choose a workspace", wait: 6
    end
end
