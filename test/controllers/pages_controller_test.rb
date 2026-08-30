require "test_helper"

class PagesControllerTest < ActionDispatch::IntegrationTest
  test "guests see the public product page" do
    get root_path

    assert_response :success
    assert_select "h1", text: /Resolve support cases with proof/
    assert_select "a", text: "Sign in to your workspace"
    assert_select "a", text: "See the support workflow"
    assert_select "body", text: /self-hosted/i
    assert_select "body", text: /does not claim SOC 2/
    assert_select "a", text: "First-time setup", count: 0
    assert_select ".proof-cell", count: 4
    assert_select ".proof-more", text: /Conversations become linked cases/
    assert_select "#how-it-works[data-controller='feature-cycle']"
    assert_select "#features", text: /Support history becomes customer context/
    assert_select "#features", text: /Know why an outcome happened/
    assert_select "#features", text: /deterministic score|signal weights|tool calls|execution budget/i, count: 0
    assert_select ".principles-section", count: 0
    assert_select ".readiness-section", count: 0
    assert_select "a[href='#hero']"
    assert_select "a[href='#how-it-works']"
    assert_select "a[href='#features']"
    assert_select "a[href='#self-host']"
    assert_select "a[href='#faq']"
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
