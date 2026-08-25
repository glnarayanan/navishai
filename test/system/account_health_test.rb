require "application_system_test_case"

class AccountHealthTest < ApplicationSystemTestCase
  test "a manager can inspect deterministic renewal risk and open a bounded crew review on mobile" do
    workspace = workspaces(:acme_support)
    account = accounts(:acme)
    owner = memberships(:owner_support)
    CrewConfiguration.install_defaults!(workspace:)
    AccountDataImport.import_api!(workspace:, membership: owner, rows: [ {
      source_id: "browser-health", account_name: account.name,
      renewal_on: (Date.current + 30.days).iso8601, contract_value: 90_000,
      active_users: 20, licensed_seats: 100
    } ])
    sign_in_in_browser(owner.user)

    page.current_window.resize_to(1440, 1000)
    visit workspace_account_path(workspace, account)
    assert_text "Deterministic signals"
    assert_text "Renewal-risk work"
    assert_text "AI analysis", count: 0
    assert_selector ".health-signals tbody tr", minimum: 6
    assert_text "Risk points subtract from 100"

    page.current_window.resize_to(320, 844)
    overflow = page.evaluate_script("Math.max(0, document.documentElement.scrollWidth - window.innerWidth)")
    offenders = page.evaluate_script(<<~JAVASCRIPT)
      Array.from(document.querySelectorAll('body *')).filter((element) => {
        const rect = element.getBoundingClientRect();
        return rect.right > window.innerWidth + 1 || rect.left < -1;
      }).slice(0, 12).map((element) => `${element.tagName}.${element.className}:${Math.round(element.getBoundingClientRect().left)}-${Math.round(element.getBoundingClientRect().right)}`)
    JAVASCRIPT
    assert_equal 0, overflow, offenders.join(", ")
    assert_operator find_button("Open risk review").rect.height, :>=, 48
    assert_operator find_link("Crew work").rect.height, :>=, 48

    click_button "Open risk review"
    assert_text "A risk review is already open. The health snapshot was refreshed."
    within "#risk-reviews" do
      assert_text "Renewal window"
      click_button "Start crew investigation"
    end
    assert_text "Investigate #{account.name} renewal risk"
    assert_text "Risk Investigator"
    assert_text "Separate deterministic facts from inference"
  end

  private
    def sign_in_in_browser(user)
      visit new_session_path
      fill_in "Email address", with: user.email_address
      fill_in "Password", with: "password12345"
      click_button "Sign in"
      assert_selector "h1", text: "Choose a workspace", wait: 6
    end
end
