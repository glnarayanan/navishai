require "test_helper"

class WorkspaceSetupChecklistsControllerTest < ActionDispatch::IntegrationTest
  test "shows honest checklist states to an Owner" do
    workspace = workspaces(:acme_support)
    sign_in_as users(:owner)

    get workspace_setup_checklist_path(workspace)

    assert_response :success
    assert_select "h1", "Setup checklist"
    assert_select "strong", "AI providers"
    assert_select "strong", "Memory"
    assert_select "strong", "Public-web search"
    assert_select "strong", "Attachments"
    assert_select "strong", "System email"
    assert_select "a[aria-label='Open AI providers']"
    assert_select "span", { text: "Skipped", count: 5 }
  end

  test "forbids a Member from opening the checklist" do
    sign_in_as users(:outsider)

    get workspace_setup_checklist_path(workspaces(:beta_support))

    assert_response :forbidden
  end
end
