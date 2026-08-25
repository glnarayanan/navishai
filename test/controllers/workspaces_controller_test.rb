require "test_helper"

class WorkspacesControllerTest < ActionDispatch::IntegrationTest
  test "lists only the signed-in user's workspaces" do
    sign_in_as users(:owner)

    get workspaces_path

    assert_response :success
    assert_select "a strong", text: workspaces(:acme_support).name
    assert_select "a strong", text: workspaces(:beta_support).name, count: 0
  end

  test "returns not found for another workspace" do
    sign_in_as users(:owner)

    get workspace_path(workspaces(:beta_support))

    assert_response :not_found
  end
end
