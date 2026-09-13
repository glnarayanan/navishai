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

    page.current_window.resize_to(1024, 900)
    assert_no_horizontal_overflow
    compare = find(".scorecard-compare-scroll")
    assert_includes %w[auto scroll], compare.evaluate_script("getComputedStyle(this).overflowX")
    assert_operator compare.evaluate_script("this.scrollWidth"), :>=, compare.evaluate_script("this.clientWidth")
    assert_selector ".scorecard-compare-table th", text: /Proposal/i
    assert_selector ".scorecard-compare-table th", text: /Change/i
    assert_not_equal "hidden", find(".scorecard-preview").evaluate_script("getComputedStyle(this).overflowX")
    page.current_window.resize_to(1440, 1100)

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
    reveal_setup "Build proposal"
    assert_operator find_button("Create proposal").rect.height, :>=, 48
    assert_operator find_button("Refresh preview and backtest").rect.height, :>=, 48
    assert_operator find_link("Accounts", match: :first).rect.height, :>=, 48
  end

  test "an owner generates and accepts a runner proposal without publishing" do
    workspace = workspaces(:acme_support)
    owner = memberships(:owner_support)
    approve_scripted_runtime(workspace:, membership: owner)
    published = HealthScorecardDesigner.install_default!(workspace:).current_version
    run = HealthScorecardProposalWorkflow.generate!(
      workspace:, membership: owner,
      prompt: "Make approaching renewal and repeated SLA breaches matter more.", admit: false
    )
    ledger = ExecutionLedger.new(workspace:)
    time = Time.current.change(usec: 0)
    output = JSON.generate(
      schema_version: 1, kind: "scorecard_proposal",
      definition: {
        "schema_version" => 1, "healthy_min" => 75, "watch_min" => 50,
        "rules" => [
          { "signal_key" => "renewal_on", "weight" => 40 },
          { "signal_key" => "sla_breaches", "weight" => 35 }
        ]
      },
      explanation: "I increased renewal proximity and SLA breach weights using only catalog signals.",
      assumptions: [ "Only retained catalog signals can change the score." ],
      unsupported_requests: [], missing_evidence: []
    )
    [
      [ 1, "run.admitted", { workspace_key: workspace.runner_key, task_key: run.crew_task.task_key, attempt: 1 } ],
      [ 2, "run.started", { adapter: "scripted", scenario: "scorecard", attempt: 1 } ],
      [ 3, "output.produced", { text: output } ],
      [ 4, "run.completed", { outcome: "completed" } ]
    ].each do |sequence, type, data|
      ledger.ingest!(event: {
        "protocol_version" => "v1", "event_id" => SecureRandom.uuid, "run_id" => run.run_key,
        "sequence" => sequence, "event_type" => type,
        "occurred_at" => (time + sequence.seconds).iso8601(6), "data" => data.deep_stringify_keys
      })
    end

    sign_in(owner.user)
    page.current_window.resize_to(1440, 1100)
    visit workspace_health_scorecard_path(workspace)
    assert_text "Ask for a constrained proposal"
    assert_text "I increased renewal proximity"
    click_button "Accept into unpublished version"
    assert_text "Proposal accepted as unpublished version"
    assert_text "Viewing a proposal — not yet published"
    assert_text "PUBLISHED"
    assert_text "Version #{published.version_number}"
    assert_no_text "Version #{workspace.health_scorecard.versions.maximum(:version_number)} is published"

    page.current_window.resize_to(320, 844)
    assert_field "What should this scorecard emphasise?"
    assert_operator find_button("Generate AI proposal").rect.height, :>=, 48
  end
end
