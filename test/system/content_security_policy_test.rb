require "application_system_test_case"

class ContentSecurityPolicyTest < ApplicationSystemTestCase
  test "landing and authenticated pages emit no CSP style violations" do
    visit root_path
    assert_selector "h1", text: /Resolve support cases with proof/
    assert_no_csp_violations

    visit new_session_path
    fill_in "Email address", with: users(:owner).email_address
    fill_in "Password", with: "password12345"
    click_button "Sign in"
    assert_selector "h1", text: "Choose a workspace"

    click_link "Acme Support"
    assert_selector "h2", text: "Case queue"
    assert_selector "dialog#app-nav-drawer[aria-label='Workspace navigation']", visible: :all
    assert_no_csp_violations
  end
end
