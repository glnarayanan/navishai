require "application_system_test_case"

class HealthScorecardTest < ApplicationSystemTestCase
  test "an owner proposes previews publishes and rolls back a scorecard on desktop and mobile" do
    workspace = workspaces(:acme_support)
    owner = memberships(:owner_support)
    account = accounts(:acme)
    AccountHealth.recalculate!(workspace:, account:, trigger_kind: "human_request", membership: owner)
    sign_in(owner.user)

    page.current_window.resize_to(1440, 1100)
    visit workspace_health_scorecard_path(workspace)
    assert_text "Health scorecard"
    assert_text "Version 1"
    fill_in "Scoring goal", with: "Put more weight on unresolved customer support work."
    find('input[name="signals[open_cases][weight]"]').set("40")
    click_button "Create proposal"

    assert_text "Proposal saved as version 2"
    assert_text "Open support cases carries up to 40 points"
    click_button "Run preview and backtest"
    assert_text "Preview and historical backtest saved"
    assert_text "snapshots tested"
    click_button "Publish version 2"
    assert_text "Version 2 now scores future account snapshots"
    assert_text "Version 2 is published"

    click_link "Version 1"
    version_one = workspace.health_scorecard.versions.find_by!(version_number: 1)
    assert_current_path workspace_health_scorecard_path(workspace, version_id: version_one.id)
    assert_selector ".scorecard-proposal h3", text: "Version 1"
    click_button "Run preview and backtest"
    assert_selector ".scorecard-proposal h3", text: "Version 1"
    click_button "Roll back to version 1"
    assert_text "Future scoring rolled back to version 1"
    assert_text "Version 1 is published"

    page.current_window.resize_to(320, 844)
    overflow = page.evaluate_script("Math.max(0, document.documentElement.scrollWidth - window.innerWidth)")
    offenders = page.evaluate_script(<<~JAVASCRIPT)
      Array.from(document.querySelectorAll('body *')).filter((element) => {
        const rect = element.getBoundingClientRect();
        return rect.right > window.innerWidth + 1 || rect.left < -1;
      }).slice(0, 12).map((element) => `${element.tagName}.${element.className}:${Math.round(element.getBoundingClientRect().left)}-${Math.round(element.getBoundingClientRect().right)}`)
    JAVASCRIPT
    assert_equal 0, overflow, offenders.join(", ")
    assert_operator find_button("Create proposal").rect.height, :>=, 48
    assert_operator find_button("Refresh preview and backtest").rect.height, :>=, 48
    assert_operator find_link("Accounts", match: :first).rect.height, :>=, 48
  end

  private
    def sign_in(user)
      visit new_session_path
      fill_in "Email address", with: user.email_address
      fill_in "Password", with: "password12345"
      click_button "Sign in"
      assert_selector "h1", text: "Choose a workspace", wait: 6
    end
end
