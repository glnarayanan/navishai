require "application_system_test_case"

class HealthEvidenceTest < ApplicationSystemTestCase
  setup do
    @workspace = workspaces(:acme_support)
    @owner = memberships(:owner_support)
    @account = @workspace.accounts.create!(name: "Lifecycle evidence")
    contact = @workspace.contacts.create!(account: @account, name: "Evidence contact")
    @first_case = create_support_case(subject: "Recurring login issue", contact:)
    @second_case = create_support_case(subject: "Login issue returned", contact:)
    tag = CaseWorkflow.create_tag!(workspace: @workspace, membership: @owner, name: "Login issue")
    CaseWorkflow.tag!(workspace: @workspace, support_case: @first_case, membership: @owner, tag:)
    CaseWorkflow.tag!(workspace: @workspace, support_case: @second_case, membership: @owner, tag:)
    @assessment = AccountHealth.recalculate!(
      workspace: @workspace, account: @account, trigger_kind: "human_request",
      membership: @owner, at: 1.second.from_now
    )
  end

  test "desktop and mobile views trace a deterministic signal to retained Support records" do
    page.current_window.resize_to(1440, 1000)
    sign_in(users(:owner))
    visit workspace_account_path(@workspace, @account)

    within ".health-signals-table" do
      row = find("tr", text: "Repeated supported issues")
      assert_text "0"
      row.click_link "View evidence"
    end
    assert_selector "h1", text: "Repeated supported issues"
    assert_text "Recurring login issue"
    assert_text "Login issue returned"
    assert_text "Human-applied tag retained on at least two cases"
    assert_link "Open source record", count: 2
    assert_equal 0, horizontal_overflow
    scroll_to_top
    save_screenshot Rails.root.join(".amp/in/artifacts/health-evidence-desktop.png") if ENV["CAPTURE_HEALTH_EVIDENCE"]

    page.current_window.resize_to(320, 760)
    visit workspace_account_path(@workspace, @account)
    assert_no_selector ".health-signals-table", visible: true
    card = find(".signal-card", text: "Repeated supported issues")
    card.find("summary").send_keys(:enter)
    assert_selector "details.signal-card[open]", text: "Repeated supported issues"
    card.click_link "View contributing records"
    assert_selector "h1", text: "Repeated supported issues"
    assert_equal 0, horizontal_overflow
    assert_operator find_link("Open source record", match: :first).evaluate_script("this.getBoundingClientRect().height"), :>=, 48
    scroll_to_top
    save_screenshot Rails.root.join(".amp/in/artifacts/health-evidence-mobile.png") if ENV["CAPTURE_HEALTH_EVIDENCE"]
  end

  private
    def horizontal_overflow
      page.evaluate_script("Math.max(0, document.documentElement.scrollWidth - window.innerWidth)")
    end

    def scroll_to_top
      page.execute_script(<<~JAVASCRIPT)
        document.documentElement.style.setProperty('scroll-behavior', 'auto', 'important');
        document.body.style.setProperty('scroll-behavior', 'auto', 'important');
        document.scrollingElement.scrollTo({ top: 0, left: 0, behavior: 'instant' });
      JAVASCRIPT
      sleep 0.1
      assert_equal 0, page.evaluate_script("window.scrollY")
    end
end
