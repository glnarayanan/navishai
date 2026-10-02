require "application_system_test_case"
require_relative "../test_helpers/evaluation_test_helper"

class MultiTurnChecksJourneyTest < ApplicationSystemTestCase
  include EvaluationTestHelper

  test "fixed response check fails a misleading transcript and passes corrected regression after blind calibration" do
    build_evaluation
    @scenario.revise!(membership: @membership, base_version_id: @scenario.current_version_id,
      attributes: { requirements: ScenarioVersion::REQUIREMENT_TYPES.index_with { [] }.merge("outcomes" => [ "When the user reports valid metadata returns 500, mention an Engineering handoff in the reply." ]) })
    @scenario.review!(membership: @membership, version_id: @scenario.current_version_id, decision: "approve", note: "Synthetic expert: the playbook requires this Engineering handoff.")
    sign_in users(:owner)
    visit workspace_corpus_graders_path(@workspace, @corpus)
    fill_in "Grader name", with: "Reply to new diagnostic evidence"
    select "Assistant response contains", from: "Check type"
    fill_in "Check value", with: "valid metadata returns 500\n\nEngineering"
    capture_states("form")
    click_button "Create grader"
    assert_selector "[role=alert]", text: /exactly two nonblank lines/
    assert_field "Check value", with: "valid metadata returns 500\n\nEngineering"
    capture_states("error")
    fill_in "Check value", with: "valid metadata returns 500\nEngineering"
    click_button "Create grader"
    assert_selector "h1", text: "Reply to new diagnostic evidence"
    grader = @corpus.graders.find_by!(name: "Reply to new diagnostic evidence")
    assert_equal "support-checks-v2", grader.current_version.processing_version
    checks = [ { "requirement_kind" => "outcomes", "requirement_index" => 0, "grader_version_id" => grader.current_version_id,
      "scenario_evidence_id" => @scenario.current_version.scenario_evidence.find_by!(kind: "expectation").id } ]
    fixed = compile_case(checks:)
    assert_not_includes fixed.scenario_version.target_input.to_json, "private answer"
    @suite.eval_suite_cases.delete_all(:delete_all)
    @suite.add_case!(membership: @membership, case_id: fixed.id)
    bad = multi_output("Try another certificate.")
    assert_equal "pass", DeterministicGrader.call(definition: { "type" => "text_contains", "value" => "Engineering" }, output: bad)["decision"]
    @target.revise!(membership: @membership, version_id: @target.current_version_id, configuration: script_configuration(output: bad))
    calls = []
    original = ScriptedTarget.method(:call)
    with_scripted_call(->(**arguments) { calls << arguments; original.call(**arguments) }) do
      failed = request_run
      2.times { EvaluationRunJob.perform_now(failed.id) }
      result = failed.reload.evaluation_run_items.sole.evaluation_result
      assert_equal "fail", result.status
      assert_equal 1, calls.size
      assert_not_includes calls.to_json, "private answer"
      regression = @corpus.eval_suites.create!(workspace: @workspace, name: "New evidence regressions", kind: "regression")
      visit workspace_corpus_evaluation_result_path(@workspace, @corpus, result)
      assert_text "assistant_response_contains: condition not met"
      select regression.name, from: "Regression suite"
      fill_in "Why this failure must not return", with: "The reply to valid metadata returning 500 must mention the Engineering handoff, not reuse earlier wording."
      capture_states("failure")
      click_button "Review and add regression"
      assert_text "Reviewed failure added to the regression suite"
      reviewed = result.regression_cases.sole
      assert_equal @membership.user, reviewed.reviewed_by
      set = CalibrationSet.define!(corpus: @corpus, membership: @membership, name: "Turn check calibration", grader_version_id: grader.current_version_id)
      sample = set.add_sample!(membership: @membership, check_id: fixed.eval_case_checks.first.id, cohort: "development", evaluation_result_id: result.id)
      assert_equal "fail", sample.calibration_prediction.result["decision"]
      assert_empty sample.human_labels
      visit workspace_corpus_calibration_set_calibration_sample_path(@workspace, @corpus, set, sample)
      assert_no_selector "h2", text: "Machine prediction"
      select "Fail — breaks the requirement", from: "Your decision"
      fill_in "Evidence for your decision", with: "Wrong response to this evidence; the playbook requires an Engineering handoff."
      click_button "Save expert label"
      assert_text "Expert label saved"
      assert_selector "h2", text: "Machine prediction"
      fixed_version_id = grader.current_version_id
      grader.revise!(membership: @membership, version_id: fixed_version_id, kind: "deterministic", definition: { "type" => "assistant_response_contains", "value" => [ "valid metadata returns 500", "unrelated revised phrase" ] })
      assert_equal [ fixed_version_id ], fixed.eval_case_checks.pluck(:grader_version_id).uniq
      @target.revise!(membership: @membership, version_id: @target.current_version_id, configuration: script_configuration(output: multi_output("I will hand these logs to ENGINEERING.")))
      passed = request_run(suite: regression)
      2.times { EvaluationRunJob.perform_now(passed.id) }
      corrected = passed.reload.evaluation_run_items.sole.evaluation_result
      assert_equal "pass", corrected.status
      assert_equal fixed.id, corrected.eval_case_id
      assert_equal 2, calls.size
      assert_not_includes calls.to_json, "private answer"
      assert_equal "fail", result.reload.status
      visit workspace_corpus_evaluation_result_path(@workspace, @corpus, corrected)
      assert_text "assistant_response_contains: condition met"
      capture_states("pass")
    end
  end

  private
    def multi_output(reply)
      support_output.merge("messages" => [ { "role" => "assistant", "content" => "Engineering can help with server errors." }, { "role" => "user", "content" => "The valid metadata returns 500." }, { "role" => "assistant", "content" => reply } ])
    end

    def capture_states(name)
      [ 1280, 390 ].each do |width|
        page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width:, height: 1600, deviceScaleFactor: 2, mobile: false)
        assert_no_horizontal_overflow
        assert_no_csp_violations
        next unless ENV["CAPTURE_LAB_SCREENSHOTS"] == "1"

        path = Rails.root.join(".amp/in/artifacts/multi-turn-checks/#{name}-#{width}.png")
        FileUtils.mkdir_p(path.dirname)
        page.execute_script("window.scrollTo(0, 0)")
        size = page.driver.browser.execute_cdp("Page.getLayoutMetrics").fetch("cssContentSize")
        image = page.driver.browser.execute_cdp("Page.captureScreenshot", captureBeyondViewport: true, clip: { x: 0, y: 0, width: size.fetch("width"), height: size.fetch("height"), scale: 1 })
        File.binwrite(path, Base64.decode64(image.fetch("data")))
      end
    end
end
