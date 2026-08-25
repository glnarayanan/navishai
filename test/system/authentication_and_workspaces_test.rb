require "application_system_test_case"

class AuthenticationAndWorkspacesTest < ApplicationSystemTestCase
  test "owner signs in and opens workspace invitations" do
    visit new_session_path

    assert_title "Sign in — NavishAI"
    assert_selector "h1", text: "Sign in"
    fill_in "Email address", with: users(:owner).email_address
    fill_in "Password", with: "password12345"
    click_button "Sign in"

    assert_selector "h1", text: "Choose a workspace"
    click_link "Acme Support"

    assert_selector "h1", text: "Acme Support"
    assert_text "Owner"
    click_link "Manage invitations"

    assert_selector "h1", text: "Workspace invitations"
    assert_title "Invitations · Acme Support — NavishAI"
    assert_field "Email address"
    assert_selector "select[name='workspace_invitation[role]'] option", count: 5

    page.current_window.resize_to(375, 812)
    assert_link "Workspaces", visible: true
  end

  test "sign-in form remains usable at a narrow viewport" do
    page.current_window.resize_to(375, 812)
    visit new_session_path

    assert_selector ".auth-panel"
    assert_field "Email address"
    assert_field "Password"
    assert_button "Sign in"
    assert_equal 375, page.evaluate_script("window.innerWidth")
    assert_operator page.evaluate_script("document.documentElement.scrollWidth - window.innerWidth"), :<=, 0
  end

  test "single sign-on remains clear and usable at 320 pixels" do
    with_oidc_configuration do
      page.current_window.resize_to(320, 844)
      visit new_session_path

      button = find_button("Continue with single sign-on")
      assert button.visible?
      assert_operator button.rect.height, :>=, 48
      assert_equal 320, page.evaluate_script("window.innerWidth")
      assert_operator page.evaluate_script("document.documentElement.scrollWidth - window.innerWidth"), :<=, 0
    end
  end

  test "keyboard users can skip the application header" do
    visit new_session_path

    find("body").send_keys(:tab)
    assert_equal "Skip to content", page.evaluate_script("document.activeElement.textContent")
    assert_equal "#main-content", find(".skip-link")[:href].delete_prefix(page.current_url)
    assert_selector "#main-content[tabindex='-1']"
  end

  private
    def with_oidc_configuration
      keys = %w[NAVISHAI_OIDC_ISSUER NAVISHAI_OIDC_CLIENT_ID NAVISHAI_OIDC_CLIENT_SECRET]
      previous = ENV.to_h.slice(*keys)
      ENV["NAVISHAI_OIDC_ISSUER"] = "https://identity.example.com"
      ENV["NAVISHAI_OIDC_CLIENT_ID"] = "navishai-system-test"
      ENV["NAVISHAI_OIDC_CLIENT_SECRET"] = "test-client-secret"
      yield
    ensure
      keys.each { |key| ENV.delete(key) }
      previous.each { |key, value| ENV[key] = value }
    end
end
