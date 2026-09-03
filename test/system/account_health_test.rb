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
    sign_in(owner.user)

    page.current_window.resize_to(1440, 1000)
    visit workspace_account_path(workspace, account)
    assert_text "Deterministic signals"
    assert_text "Renewal-risk work"
    assert_text "AI analysis", count: 0
    assert_selector ".health-signals tbody tr", minimum: 6
    assert_text "Risk points subtract from 100"

    last_cell = page.evaluate_script(<<~JAVASCRIPT)
      (() => {
        const cell = document.querySelector('.health-signals tbody tr td:last-child')
        const frame = document.querySelector('.app-shell')
        const scroller = document.querySelector('.health-signals-table')
        const cellRect = cell.getBoundingClientRect()
        const frameRect = frame.getBoundingClientRect()
        const scrollRect = scroller.getBoundingClientRect()
        return {
          clipped: cellRect.right - frameRect.right,
          contained: cellRect.right - scrollRect.right,
          scrollable: scroller.scrollWidth - scroller.clientWidth,
          regionClient: scroller.clientWidth,
          regionScroll: scroller.scrollWidth,
          citationClient: cell.clientWidth,
          citationScroll: cell.scrollWidth
        }
      })()
    JAVASCRIPT
    assert_operator last_cell["scrollable"], :<=, 0, last_cell.inspect
    assert_operator last_cell["clipped"], :<=, 1, last_cell.inspect
    assert_operator last_cell["contained"], :<=, 1, last_cell.inspect
    assert_operator last_cell["citationScroll"], :<=, last_cell["citationClient"] + 1, last_cell.inspect

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

  test "account rows keep list and link semantics" do
    workspace = workspaces(:acme_support)
    sign_in(users(:owner))
    visit workspace_accounts_path(workspace)

    assert_selector "[role='list'] [role='listitem'] a", text: accounts(:acme).name
  end
end
