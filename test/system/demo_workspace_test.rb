require "application_system_test_case"

class DemoWorkspaceTest < ApplicationSystemTestCase
  test "the seeded owner can review Support and Customer Success work on desktop and mobile" do
    original_seed_demo = ENV["NAVISHAI_SEED_DEMO"]
    ENV["NAVISHAI_SEED_DEMO"] = "1"
    load Rails.root.join("db/seeds.rb")
    workspace = Organization.find_by!(slug: "navishai-demo").workspaces.find_by!(slug: "customer-operations")
    owner = workspace.memberships.owners.sole.user

    visit new_session_path
    fill_in "Email address", with: owner.email_address
    fill_in "Password", with: "navishai-demo-password"
    click_button "Sign in"
    click_link "Customer Operations"

    page.current_window.resize_to(1440, 1000)
    assert_text "SSO access fails for the onboarding team"
    assert_text "Weekly usage export"
    assert_equal 0, page.evaluate_script("Math.max(0, document.documentElement.scrollWidth - window.innerWidth)")
    visit workspace_account_path(workspace, workspace.accounts.find_by!(name: "Northstar Labs"))
    assert_text "Deterministic signals"
    assert_text "Renewal-risk work"

    page.current_window.resize_to(320, 844)
    overflow = page.evaluate_script("Math.max(0, document.documentElement.scrollWidth - window.innerWidth)")
    assert_equal 0, overflow
    assert_operator find_link("Cases", match: :first).rect.height, :>=, 48
    assert_operator find_link("Accounts", match: :first).rect.height, :>=, 48
  ensure
    ENV["NAVISHAI_SEED_DEMO"] = original_seed_demo
  end
end
