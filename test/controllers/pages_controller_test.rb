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
    assert_select "a", text: "First-time setup", count: 0
    assert_select ".principle-stage[aria-hidden=true]"
    assert_select ".principle-column", count: 3
    assert_select ".principle-static"
    assert_select ".principle-static[aria-hidden]", count: 0
  end

  test "authenticated people are sent to workspaces" do
    sign_in_as users(:owner)

    get root_path

    assert_redirected_to workspaces_path
  end

  test "public pages keep style-src self and host Geist from the asset pipeline" do
    get root_path

    assert_response :success
    csp = response.headers["Content-Security-Policy"].to_s
    assert_match(/style-src 'self'/, csp)
    refute_match(/style-src[^;]*'unsafe-inline'/, csp)
    assert Rails.application.assets.load_path.find("Geist-Variable.woff2")
    assert Rails.application.assets.load_path.find("GeistMono-Variable.woff2")
  end
end
