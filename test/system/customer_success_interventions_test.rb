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
    sign_in(@owner.user)
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

  test "managers reassign and reschedule from the account with keyboard and compact layouts" do
    member = @workspace.memberships.create!(
      user: User.create!(
        email_address: "follow-up-ui-#{SecureRandom.hex(3)}@example.com",
        password: "password12345", verified_at: Time.current
      ),
      role: :member
    )
    intervention = propose_test_intervention(
      workspace: @workspace, account: @account, membership: @owner,
      assessment: @assessment, artifact: @plan, at: Time.current.change(usec: 0)
    )

    page.current_window.resize_to(1440, 1000)
    visit workspace_account_path(@workspace, @account)
    reassign = find(".intervention-follow-up", text: "Reassign")
    reassign.find("summary").send_keys(:enter)
    assert reassign.evaluate_script("this.open")
    within reassign do
      select member.user.email_address, from: "Accountable human"
      fill_in "Why reassign?", with: "Coverage moved to another writable human."
      click_button "Record new owner"
    end
    assert_text "Intervention ownership recorded for a different eligible human."
    assert_text "Accountable to #{member.user.email_address}"

    reschedule = find(".intervention-follow-up", text: "Change follow-up date")
    reschedule.find("summary").click
    next_date = intervention.target_on + 5.days
    within reschedule do
      fill_in "Follow-up date", with: next_date
      fill_in "Why change the date?", with: "The Account asked for more time."
      click_button "Record follow-up date"
    end
    assert_text "Follow-up date changed with a recorded reason."
    assert_text "Follow up #{next_date.to_fs(:long)}"

    click_button "Approve intervention"
    Capybara.reset_sessions!
    sign_in(member.user)
    visit workspace_account_path(@workspace, @account)
    assert_no_text "Reassign"
    assert_no_text "Change follow-up date"
    click_button "Record human completion"
    assert_text "Human completion recorded. No customer message was sent or scheduled."
    assert_text "Completed · outcome review pending"

    page.current_window.resize_to(390, 844)
    refresh
    assert_text "Completed · outcome review pending"
    assert_equal 0, horizontal_overflow

    page.current_window.resize_to(320, 844)
    refresh
    assert_text "Completed · outcome review pending"
    assert_equal 0, horizontal_overflow
    assert_operator find(".intervention-outcome-pending").rect.height, :>=, 16
  end

  private
    def horizontal_overflow
      page.evaluate_script("Math.max(0, document.documentElement.scrollWidth - window.innerWidth)")
    end
end
