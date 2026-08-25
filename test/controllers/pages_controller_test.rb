require "test_helper"

class PagesControllerTest < ActionDispatch::IntegrationTest
  test "guests see the public product page" do
    get root_path

    assert_response :success
    assert_select "h1", text: /Specialist AI crews/
    assert_select "a", text: "Sign in"
    assert_select "a", text: "See how it works"
    assert_select "body", text: /self-hosted/i
    assert_select "body", text: /does not claim SOC 2/
    assert_select "a", text: "First-time setup"
  end

  test "authenticated people are sent to workspaces" do
    sign_in_as users(:owner)

    get root_path

    assert_redirected_to workspaces_path
  end
end
