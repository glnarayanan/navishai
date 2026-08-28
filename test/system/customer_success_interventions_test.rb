require "application_system_test_case"

class CustomerSuccessInterventionsTest < ApplicationSystemTestCase
  setup do
    @workspace = workspaces(:acme_support)
    @owner = memberships(:owner_support)
    @account = accounts(:acme)
    @assessment = AccountHealth.recalculate!(
      workspace: @workspace, account: @account, trigger_kind: "human_request",
      membership: @owner, at: Time.current.change(usec: 0)
    )
    @plan, = create_reviewed_intervention_plan(
      workspace: @workspace, account: @account, membership: @owner, assessment: @assessment
    )
    sign_in_in_browser(@owner.user)
  end

  test "human owns intervention decisions and reviews observed outcomes on desktop and mobile" do
    page.current_window.resize_to(1440, 1000)
    visit workspace_account_path(@workspace, @account)

    assert_selector "#customer-success-interventions h2", text: "Interventions and observed outcomes"
    assert_text "Nothing here sends or schedules customer communication."
    assert_text "Reviewed AI proposals"
    find(".intervention-proposal > summary").click
    fill_in "Expected observable change", with: "Raise the next deterministic health score."
    fill_in "Follow-up date", with: Date.current + 7.days
    fill_in "Why record this intervention?", with: "The human Account owner accepted this reviewed plan."
    click_button "Record proposed intervention"

    assert_text "Proposed intervention recorded for human review."
    assert_selector ".intervention-card", count: 1
    assert_selector ".intervention-layers section", text: /AI analysis/i
    assert_selector ".intervention-layers section", text: /Deterministic facts/i
    assert_selector ".intervention-layers section", text: /Human decision/i
    assert_no_text "Observed outcome"
    click_button "Approve intervention"
    assert_text "Intervention approved by a human Manager."
    click_button "Record human completion"
    assert_text "Human completion recorded. No customer message was sent or scheduled."

    intervention = @workspace.customer_success_interventions.order(:id).last
    after_assessment = AccountHealth.recalculate!(
      workspace: @workspace, account: @account, trigger_kind: "human_request",
      membership: @owner, at: intervention.completed_at + 1.minute
    )
    refresh
    find(".intervention-review-form > summary").click
    select "#{after_assessment.calculated_at.to_fs(:short)} · #{after_assessment.score}/100 · #{after_assessment.risk_level.humanize}",
      from: "After assessment"
    fill_in "What remains uncertain?", with: "Timing and association do not prove cause."
    click_button "Freeze observed review"

    assert_text "Observed outcome review frozen without a causal claim."
    assert_selector ".intervention-outcome", text: "Frozen before-and-after review"
    assert_text "association only; it does not assign cause"
    assert_text "Timing and association do not prove cause."
    disclosure = find(".intervention-card .record-disclosure > summary")
    disclosure.send_keys(:enter)
    assert disclosure.find(:xpath, "..").evaluate_script("this.open")
    assert_equal 0, horizontal_overflow
    save_screenshot Rails.root.join(".amp/in/artifacts/customer-success-intervention-desktop.png") if
      ENV["CAPTURE_CUSTOMER_SUCCESS_INTERVENTIONS"]

    mobile_plan, = create_reviewed_intervention_plan(
      workspace: @workspace, account: @account, membership: @owner, assessment: @assessment
    )
    propose_test_intervention(
      workspace: @workspace, account: @account, membership: @owner,
      assessment: @assessment, artifact: mobile_plan, at: Time.current.change(usec: 0)
    )
    overdue_plan, = create_reviewed_intervention_plan(
      workspace: @workspace, account: @account, membership: @owner, assessment: @assessment
    )
    CustomerSuccessInterventionWorkflow.propose!(
      workspace: @workspace, membership: @owner, account: @account,
      assessment: @assessment, artifact: overdue_plan, accountable_membership: @owner,
      expected_observable_change: "Review the overdue observed change.",
      target_on: Date.yesterday, reason: "This bounded follow-up is overdue.",
      at: 2.days.ago.change(usec: 0)
    )

    page.current_window.resize_to(320, 844)
    refresh
    assert_selector ".intervention-card", count: 3
    assert_selector ".intervention-overdue", count: 1
    assert_equal 0, horizontal_overflow
    assert_operator find_button("Approve intervention", match: :first).rect.height, :>=, 48
    abandon = find(".intervention-abandon", match: :first)
    assert_operator abandon.find("summary").rect.height, :>=, 48
    abandon.find("summary").click
    within abandon do
      fill_in "Bounded reason", with: "The human owner chose another path."
      click_button "Record abandonment"
    end
    assert_text "Intervention abandoned with a human decision."
    assert_equal 0, horizontal_overflow
    if ENV["CAPTURE_CUSTOMER_SUCCESS_INTERVENTIONS"]
      page.execute_script(
        "document.documentElement.style.scrollBehavior = 'auto'; arguments[0].scrollIntoView({ block: 'start' })",
        find(".intervention-card", match: :first)
      )
      save_screenshot Rails.root.join(".amp/in/artifacts/customer-success-intervention-mobile.png")
    end

    empty_account = @workspace.accounts.create!(name: "No intervention evidence")
    visit workspace_account_path(@workspace, empty_account)
    assert_text "No human-owned intervention is recorded"
    assert_text "A complete cited plan needs an approved success review"
  end

  private
    def sign_in_in_browser(user)
      visit new_session_path
      fill_in "Email address", with: user.email_address
      fill_in "Password", with: "password12345"
      click_button "Sign in"
      assert_selector "h1", text: "Choose a workspace", wait: 6
    end

    def horizontal_overflow
      page.evaluate_script("Math.max(0, document.documentElement.scrollWidth - window.innerWidth)")
    end
end
