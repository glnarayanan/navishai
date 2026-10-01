require "application_system_test_case"
require_relative "../support/failure_matching_fixture"
require_relative "../test_helpers/evaluation_test_helper"

class FailureMatchingJourneyTest < ApplicationSystemTestCase
  include FailureMatchingFixture
  include EvaluationTestHelper

  test "a matched trace revises the existing scenario through expert review compilation and regression" do
    build_failure_matching_fixture
    @workspace = @corpus.workspace
    @scenario = @version.scenario
    requirements = ScenarioVersion::REQUIREMENT_TYPES.index_with { [] }.merge("outcomes" => [ "Request expiry evidence before changing configuration." ])
    original = @scenario.revise!(membership: @membership, base_version_id: @version.id,
      attributes: { requirements:, hidden_facts: { "actual_cause" => "private diagnostic answer" } })
    @scenario.review!(membership: @membership, version_id: original.id, decision: "approve", note: "Synthetic expert checked the certificate policy.")
    @outcome_grader = Grader.define!(corpus: @corpus, membership: @membership, name: "Request expiry", kind: "deterministic", definition: { "type" => "text_contains", "value" => "expiry date" })
    @action_grader = Grader.define!(corpus: @corpus, membership: @membership, name: "Collect expiry", kind: "deterministic", definition: { "type" => "tool_called", "value" => "collect_expiry" })
    old_case = EvalCompiler.call(scenario: @scenario, membership: @membership, version_id: original.id, checks: [ {
      "requirement_kind" => "outcomes", "requirement_index" => 0, "grader_version_id" => @outcome_grader.current_version_id,
      "scenario_evidence_id" => original.scenario_evidence.sole.id } ])
    sign_in users(:owner)
    visit source_path
    select "Match", from: "Decision for scenario #{@scenario.id} v#{original.number}"
    fill_in "Reason for this association", with: "Synthetic expert: same certificate workflow; update its entitlement and required evidence."
    click_button "Append trace decision"
    assert_text "Trace decision appended"
    association = TraceScenarioDecision.where(corpus_item: @item).sole
    click_link "Revise with this trace", match: :first
    assert_field "Customer starting situation", with: original.situation
    assert_equal original.known_facts, JSON.parse(find_field("Known facts (JSON object)", visible: :all).value)
    assert_field "Exact source excerpt", with: ""
    assert_equal @item.id.to_s, find_field("Source record").value
    assert_link "Inspect selected trace: #{@item.title}", href: workspace_corpus_source_path(@workspace, @corpus, @item.source_snapshot.source,
      snapshot: 1, page: 1, anchor: "record-#{@item.id}")
    [ 1280, 390 ].each { |width| capture("selected-trace-#{width}", width, selector: "#scenario-evidence") }
    trace = SupportTrace.payload(@item)
    fill_in "Customer starting situation", with: trace.fetch("input").fetch("situation")
    find("summary", text: "Known and hidden facts").click
    fill_in "Known facts (JSON object)", with: trace.fetch("input").fetch("known_facts").to_json
    fill_in "Actions — one requirement per line", with: "Collect the certificate expiry date."
    fill_in "Exact source excerpt", with: "Keep my invalid source quote"
    click_button "Save new version"
    assert_selector "[role=alert]", text: /must occur in its source record/
    assert_selector "#evidence-error", text: "No version saved. Read the exact source record, paste a matching excerpt and save again."
    assert_field "Exact source excerpt", with: "Keep my invalid source quote"
    assert_equal "true", find_field("Exact source excerpt")["aria-invalid"]
    assert_equal original.id, @scenario.reload.current_version_id
    [ 1280, 390 ].each do |width|
      capture("trace-error-#{width}", width, selector: "#scenario-evidence")
      capture("trace-error-notice-#{width}", width, selector: "[role=alert]")
    end
    fill_in "Exact source excerpt", with: "Request the certificate expiry date first."
    click_button "Save new version"
    assert_text "Version 3 · expert · needs review"
    revised = @scenario.reload.current_version
    assert_not revised.approved?
    assert_no_link "Compile eval"
    assert_equal @item.id, revised.scenario_evidence.find_by!(corpus_item: @item).corpus_item_id
    assert_empty original.reload.scenario_evidence.where(corpus_item: @item)
    assert_equal original.id, old_case.reload.scenario_version_id
    assert_equal original.id, association.reload.scenario_version_id
    fill_in "Decision note", with: "Synthetic expert checked current company policy and this exact reported correction."
    click_button "Save expert decision"
    assert_text "Version 3 · expert · approve"
    click_link "Compile eval"
    revised.requirements.each do |kind, statements|
      statements.each_index do |index|
        grader = kind == "actions" ? @action_grader : @outcome_grader
        select "#{grader.name} · v1", from: "Grader for #{kind} #{index + 1}"
        select "#{@item.title} · expectation", from: "Source for #{kind} #{index + 1}"
      end
    end
    click_button "Compile fixed case"
    assert_text "Contract compiled with fixed graders"
    fixed_case = @corpus.eval_cases.order(:id).last
    assert_equal revised.id, fixed_case.scenario_version_id
    assert_equal [ @item.id ], fixed_case.eval_case_checks.map { |check| check.scenario_evidence.corpus_item_id }.uniq
    @suite = @corpus.eval_suites.create!(workspace: @workspace, name: "Updated certificate workflow")
    @suite.add_case!(membership: @membership, case_id: fixed_case.id)
    @target = EvaluationTarget.define!(corpus: @corpus, membership: @membership, name: "Matched trace replay", adapter: "recorded", configuration: {}, trace_item_id: @item.id)
    run = request_run
    2.times { EvaluationRunJob.perform_now(run.id) }
    result = run.reload.evaluation_results.sole
    assert_equal "fail", result.status
    assert_not result.evaluation_run_item.target_input.to_json.include?("private diagnostic answer")
    visit workspace_corpus_evaluation_result_path(@workspace, @corpus, result)
    regression = @corpus.eval_suites.create!(workspace: @workspace, name: "Matched trace regressions", kind: "regression")
    visit current_url
    select "Matched trace regressions", from: "Regression suite"
    fill_in "Why this failure must not return", with: "Synthetic expert: this recorded failure skipped the required certificate evidence."
    click_button "Review and add regression"
    assert_selector "h1", text: "Matched trace regressions"
    assert_equal fixed_case.id, regression.eval_cases.sole.id
    capture("trace-regression-390", 390)
    @target.revise!(membership: @membership, version_id: @target.current_version_id, adapter: "scripted",
      configuration: script_configuration(output: support_output(tools: [ "collect_expiry" ])))
    corrected = request_run(suite: regression, version: @target.reload.current_version)
    EvaluationRunJob.perform_now(corrected.id)
    assert_equal "pass", corrected.reload.evaluation_results.sole.status
    assert_equal fixed_case.id, corrected.evaluation_results.sole.eval_case_id
    assert_equal "fail", result.reload.status
    assert_equal 1, @corpus.scenarios.count
    assert_empty HumanLabel.where(corpus: @corpus)
  end

  test "expert inspects conflict appends history and sees retained stale error empty and viewer states" do
    build_failure_matching_fixture
    sign_in users(:owner)
    visit source_path
    assert_text "Exact shared terms:"
    assert_text "Conflicting known facts — review caution"
    select "Match", from: "Decision for scenario #{@version.scenario_id} v1"
    fill_in "Reason for this association", with: "Certificate failure overlaps; plan differs."
    click_button "Append trace decision"
    assert_text "Trace decision appended"
    select "Uncertain", from: "Decision for scenario #{@version.scenario_id} v1"
    fill_in "Reason for this association", with: "Need logs before treating these as the same issue."
    click_button "Append trace decision"
    assert_text "Trace decision appended"
    assert_text "Earlier decision"
    [ 1280, 390 ].each { |width| capture("conflicts-history-#{width}", width) }
    @version.scenario.revise!(membership: @membership, base_version_id: @version.id, attributes: { title: "Updated certificate diagnostics" })
    fill_in "Reason for this association", with: "Keep my stale explanation."
    click_button "Append trace decision"
    assert_selector "[role=alert]", text: "Choose a current"
    assert_text "Keep my stale explanation."
    [ 1280, 390 ].each { |width| capture("retained-error-#{width}", width) }
    @version.scenario.reload.current_version.scenario.review!(membership: @membership, version_id: @version.scenario.current_version_id, decision: "reject")
    visit source_path
    assert_text "No candidates share at least two meaningful terms"
    capture("empty-390", 390)
    Membership.create!(workspace: @corpus.workspace, user: users(:teammate), role: :viewer)
    find(".lab-navigation summary").click
    click_button "Sign out"
    sign_in users(:teammate)
    visit source_path
    assert_no_button "Append trace decision"
    assert_no_link "Revise with this trace"
    assert_text "Expert associations and history"
    capture("viewer-390", 390)
  end

  test "expert selects a missed scenario repairs a stale association and opens exact trace evidence" do
    build_failure_matching_fixture
    policy = CorpusIntake.call(corpus: @corpus, membership: @membership, name: "Quota guidance", kind: "document", bytes: "Retry after cooldown.").corpus_items.sole
    missed = matching_version(title: "Request quota", situation: "Request quota exhausted; retry after cooldown.", facts: { "plan" => "enterprise" }, item: policy, excerpt: policy.content)
    trace = JSON.parse(File.read(Rails.root.join("test/fixtures/files/production_traces.json"))).sole
    trace.merge!("id" => "rate-failure", "title" => "Immediate retry failure", "observed_failure" => "Assistant resends immediately.", "human_correction" => "Wait before resending.")
    trace["input"] = { "situation" => "Traffic ceiling reached; wait before resending.", "known_facts" => { "plan" => "enterprise" }, "knowledge" => [] }
    trace["output"]["messages"] = [ { "role" => "assistant", "content" => "I will resend immediately." } ]
    @item = CorpusIntake.call(corpus: @corpus, membership: @membership, name: "Quota traces", kind: "traces", bytes: [ trace ].to_json).corpus_items.sole
    assert_empty TraceScenarioMatching.call(item: @item).candidates
    sign_in users(:owner)
    visit source_path
    assert_text "No candidates share at least two meaningful terms"
    find("summary", text: "Inspect an existing scenario").click
    fill_in "Scenario ID for trace rate-failure", with: missed.scenario_id
    find("input[value='Inspect selected scenario']").send_keys(:enter)
    assert_selector "#selected-scenario-#{@item.id} h5", text: "Expert-selected scenario"
    assert_field "Decision for scenario #{missed.scenario_id} v1", with: "uncertain"
    assert_empty TraceScenarioDecision.where(corpus: @corpus)
    assert_empty missed.scenario_reviews
    [ 1280, 390 ].each { |width| capture("manual-selected-#{width}", width, selector: "#selected-scenario-#{@item.id}") }

    revised = missed.scenario.revise!(membership: @membership, base_version_id: missed.id, attributes: { title: "Request quota diagnostics" })
    select "Match", from: "Decision for scenario #{missed.scenario_id} v1"
    fill_in "Reason for this association", with: "Authored expert: same quota workflow despite different words."
    click_button "Append trace decision"
    assert_selector "[role=alert]", text: "Choose a current"
    assert_text "No decision was saved or moved to a newer version"
    assert_text "Authored expert: same quota workflow despite different words."
    assert_no_button "Append trace decision"
    assert_empty TraceScenarioDecision.where(corpus: @corpus)
    [ 1280, 390 ].each { |width| capture("manual-stale-#{width}", width) }
    find("input[value='Inspect selected scenario']").send_keys(:enter)
    assert_field "Decision for scenario #{missed.scenario_id} v2", with: "uncertain"
    assert_field "Reason for this association", with: ""
    select "Match", from: "Decision for scenario #{missed.scenario_id} v2"
    fill_in "Reason for this association", with: "Authored expert checked this exact current version."
    click_button "Append trace decision"
    assert_text "Trace decision appended"
    assert_equal revised.id, TraceScenarioDecision.where(corpus_item: @item).sole.scenario_version_id
    assert_not revised.reload.approved?
    find("summary", text: "Inspect an existing scenario").click
    fill_in "Scenario ID for trace rate-failure", with: missed.scenario_id
    find("input[value='Inspect selected scenario']").send_keys(:enter)
    click_link "Revise selected scenario with this trace"
    assert_equal @item.id.to_s, find_field("Source record").value
    assert_field "Customer starting situation", with: "Request quota exhausted; retry after cooldown."
    assert_field "Exact source excerpt", with: ""
    assert_field "Outcomes — one requirement per line", with: ""
    assert_link "Inspect selected trace: #{@item.title}", href: workspace_corpus_source_path(@corpus.workspace, @corpus, @item.source_snapshot.source, snapshot: 1, page: 1, anchor: "record-#{@item.id}")
    [ 1280, 390 ].each { |width| capture("manual-revision-#{width}", width, selector: "#scenario-evidence") }
    assert_equal revised.id, missed.scenario.reload.current_version_id
    assert_empty HumanLabel.where(corpus: @corpus)
  end

  test "nested numeric differences appear as conflicts rather than equal known facts" do
    build_failure_matching_fixture
    integers = { "steps" => [ 0, { "budget" => 2 } ], "zone" => "west" }
    floats = { "zone" => "west", "steps" => [ 0.0, { "budget" => 2 } ] }
    @version = @version.scenario.revise!(membership: @membership, base_version_id: @version.id,
      attributes: { known_facts: @version.known_facts.merge("limits" => integers) })
    record = JSON.parse(File.read(Rails.root.join("test/fixtures/files/production_traces.json"))).sole
    record["input"]["known_facts"]["limits"] = floats
    @item = CorpusIntake.call(corpus: @corpus, membership: @membership, name: "Nested typed facts", kind: "traces", bytes: [ record ].to_json).corpus_items.sole
    sign_in users(:owner)
    visit source_path
    within find("h6", text: "Conflicting known facts — review caution").find(:xpath, "..") do
      limits = JSON.parse(find("pre").text).fetch("limits")
      assert floats.eql?(limits["trace"])
      assert integers.eql?(limits["scenario"])
    end
    within find("h6", text: "Equal known facts").find(:xpath, "..") do
      assert_equal({ "idp" => "Okta" }, JSON.parse(find("pre").text))
    end
    [ 1280, 390 ].each { |width| capture("nested-conflicts-#{width}", width) }
    assert_empty TraceScenarioDecision.where(corpus: @corpus)
    assert_empty @version.scenario_reviews
  end

  private
    def source_path
      workspace_corpus_source_path(@corpus.workspace, @corpus, @item.source_snapshot.source)
    end

    def capture(name, width, selector: nil)
      page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width:, height: 1000, deviceScaleFactor: 2, mobile: false)
      assert_no_horizontal_overflow
      assert_no_csp_violations
      return unless ENV["CAPTURE_LAB_SCREENSHOTS"] == "1"
      path = Rails.root.join(".amp/in/artifacts/failure-matching/#{name}.png")
      FileUtils.mkdir_p(path.dirname)
      image = if selector
        page.execute_script("document.querySelector(#{selector.to_json}).scrollIntoView({block: 'start'})")
        page.driver.browser.execute_cdp("Page.captureScreenshot", captureBeyondViewport: false)
      else
        page.execute_script("window.scrollTo(0, 0)")
        size = page.driver.browser.execute_cdp("Page.getLayoutMetrics").fetch("cssContentSize")
        page.driver.browser.execute_cdp("Page.captureScreenshot", captureBeyondViewport: true,
          clip: { x: 0, y: 0, width:, height: size.fetch("height"), scale: 1 })
      end
      File.binwrite(path, Base64.decode64(image.fetch("data")))
    end
end
