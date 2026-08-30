require "application_system_test_case"

class OutcomeExplanationsSystemTest < ApplicationSystemTestCase
  test "an operator reaches one read-only explanation from case Account run and health surfaces" do
    workspace = workspaces(:acme_support)
    owner = memberships(:owner_support)
    support_case = create_support_case(subject: "Browser explanation path")
    account = support_case.conversation.contact.account
    artifact = create_draft_artifact(
      workspace:, support_case:, membership: owner,
      body: "Current grounded browser outcome", result_state: "complete"
    )
    assessment = AccountHealth.recalculate!(
      workspace:, account:, trigger_kind: "human_request", membership: owner,
      at: Time.current.change(usec: 0)
    )
    sign_in(owner.user)

    page.current_window.resize_to(1440, 1100)
    visit workspace_support_case_path(workspace, support_case)
    click_link "Explain this outcome"
    assert_selector "h1", text: "Explain this outcome"
    assert_selector ".explanation-state-complete", text: "Complete"
    assert_text "no explanation narrative is stored"
    assert_no_selector ".outcome-explanation form"
    summary = find("summary", text: "Outcome text, uncertainty, and conflicts")
    summary.send_keys(:enter)
    assert summary.ancestor("details")[:open]
    assert_text "Current grounded browser outcome"
    find("body").send_keys(:tab)
    assert page.evaluate_script("document.activeElement.matches('a, button, input, select, summary, textarea')")
    save_screenshot Rails.root.join(".amp/in/artifacts/outcome-explanation-desktop.png") if ENV["CAPTURE_OUTCOME_EXPLANATION"]

    visit workspace_account_path(workspace, account)
    click_link "Explain this outcome"
    assert_selector ".explanation-heading", text: /Account/
    click_link "Back to account"
    click_link "Explain this health assessment"
    assert_selector "#health-lineage-title", text: "Health outcome and evidence"
    assert_text "Scorecard"

    visit workspace_support_case_crew_task_path(workspace, support_case, artifact.crew_task)
    click_link "Explain this run"
    assert_selector ".explanation-heading", text: /Execution run/
    assert_text "Searches are task-scoped"

    open_workspace_nav
    click_link "Usage & rates", match: :first
    assert_selector "h1", text: "Usage and rates"
    assert_text "unavailable rather than zero"
    fill_in "Currency", with: "USD"
    fill_in "Rate source", with: "Browser-tested public rate"
    fill_in "Input cost per 1M units", with: "2"
    fill_in "Output cost per 1M units", with: "4"
    fill_in "Search cost per 1M units", with: "1"
    click_button "Publish rate version"
    assert_text "Usage rate version published"
    assert_selector ".usage-rate-current", text: /v1/

    page.current_window.resize_to(320, 844)
    assert_no_horizontal_overflow
    assert_operator find_button("Publish rate version").rect.height, :>=, 48
    visit workspace_outcome_explanation_path(
      workspace, subject_type: "case", subject_id: support_case.id
    )
    assert_no_horizontal_overflow
    assert_operator find_link("Review configured rates").rect.height, :>=, 48
    save_screenshot Rails.root.join(".amp/in/artifacts/outcome-explanation-mobile.png") if ENV["CAPTURE_OUTCOME_EXPLANATION"]

    member = create_membership(workspace, "usage-browser-member@example.com", :member)
    reset_session!
    sign_in(member.user)
    page.current_window.resize_to(1440, 900)
    visit workspace_usage_rates_path(workspace)
    assert_text "Usage and rates"
    assert_no_button "Publish rate version"
    page.execute_script(<<~JAVASCRIPT)
      const form = document.createElement("form");
      form.method = "post";
      form.action = "#{workspace_usage_rates_path(workspace)}";
      document.body.appendChild(form);
      form.submit();
    JAVASCRIPT
    assert_selector "h1", text: "You can’t change usage rates"
    assert_link "Back to usage rates"
  end

  test "empty stale blocked review degraded and success states stay explicit" do
    workspace = workspaces(:acme_support)
    owner = memberships(:owner_support)
    empty_case = create_support_case(subject: "No explanation data")
    success_case = create_support_case(subject: "Complete explanation")
    stale_case = create_support_case(subject: "Stale explanation")
    blocked_case = create_support_case(subject: "Blocked explanation")
    review_case = create_support_case(subject: "Review explanation")
    degraded_case = create_support_case(subject: "Degraded explanation")
    create_draft_artifact(
      workspace:, support_case: success_case, membership: owner,
      body: "Complete retained outcome", result_state: "complete"
    )
    create_draft_artifact(
      workspace:, support_case: stale_case, membership: owner,
      body: "Stale retained outcome", result_state: "needs_human", evidence_status: "stale"
    )
    create_draft_artifact(
      workspace:, support_case: blocked_case, membership: owner,
      body: "Blocked retained outcome", result_state: "blocked", evidence_status: "conflicted",
      claim_state: "conflicted"
    )
    create_draft_artifact(
      workspace:, support_case: review_case, membership: owner,
      body: "Human review retained outcome", result_state: "needs_human", claim_state: "uncertain"
    )
    profile = workspace.agent_profiles.find_by!(role_key: "support_coordinator")
    task = CrewWork.create!(
      workspace:, membership: owner, scope: degraded_case, profile:,
      title: "Failed browser run", input_context: "Use retained facts.",
      expected_output: "Return a bounded result."
    )
    run = ExecutionLedger.new(workspace:).prepare!(task:, request_key: "browser:degraded")
    ingest(workspace, run, 1, "run.admitted",
      workspace_key: workspace.runner_key, task_key: task.task_key, attempt: run.attempt_number)
    ingest(workspace, run, 2, "run.started",
      adapter: "scripted", scenario: "browser degraded", attempt: run.attempt_number)
    ingest(workspace, run, 3, "run.failed", code: "browser_failure", retryable: false)
    sign_in(owner.user)

    assert_case_state(workspace, empty_case, "empty", "No crew artifact")
    assert_case_state(workspace, success_case, "complete", "Current")
    assert_case_state(workspace, stale_case, "needs-human", "Stale")
    assert_case_state(workspace, blocked_case, "blocked", "Conflicted")
    assert_case_state(workspace, review_case, "needs-human", "Uncertain")
    assert_case_state(workspace, degraded_case, "degraded", "Failure and recovery")

    original = OutcomeExplanation.method(:resolve!)
    OutcomeExplanation.define_singleton_method(:resolve!) do |**|
      raise ActiveRecord::ConnectionNotEstablished, "private browser database detail"
    end
    visit workspace_outcome_explanation_path(
      workspace, subject_type: "case", subject_id: success_case.id
    )
    assert_selector "h1", text: "Explanation couldn’t be loaded"
    assert_text "No outcome or usage value was inferred"
    assert_no_text "private browser database detail"
    OutcomeExplanation.define_singleton_method(:resolve!, original)

    page.current_window.resize_to(320, 844)
    assert_no_horizontal_overflow
  ensure
    OutcomeExplanation.define_singleton_method(:resolve!, original) if original
  end

  private
    def sign_in(user)
      visit new_session_path
      fill_in "Email address", with: user.email_address
      fill_in "Password", with: "password12345"
      click_button "Sign in"
      assert_selector "h1", text: "Choose a workspace", wait: 6
    end

    def create_membership(workspace, email, role)
      user = User.create!(email_address: email, password: "password12345", verified_at: Time.current)
      workspace.memberships.create!(user:, role:)
    end

    def assert_case_state(workspace, support_case, state, text)
      visit workspace_outcome_explanation_path(
        workspace, subject_type: "case", subject_id: support_case.id
      )
      assert_selector ".explanation-state-#{state}"
      assert_text text
    end

    def ingest(workspace, run, sequence, event_type, **data)
      ExecutionLedger.new(workspace:).ingest!(event: {
        "protocol_version" => "v1", "event_id" => SecureRandom.uuid, "run_id" => run.run_key,
        "sequence" => sequence, "event_type" => event_type,
        "occurred_at" => (Time.current.change(usec: 0) + sequence.seconds).iso8601(6),
        "data" => data.stringify_keys
      })
    end
end
