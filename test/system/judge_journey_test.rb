require "application_system_test_case"
require_relative "../test_helpers/judge_test_helper"

class JudgeJourneyTest < ApplicationSystemTestCase
  include JudgeTestHelper

  test "experts consent calibrate inspect judge evidence and retain a fixed regression without automatic disclosure" do
    build_judge_evaluation
    sample = judge_sample
    sign_in users(:owner)
    with_endpoint_approval do
      visit workspace_corpus_grader_path(@workspace, @corpus, @outcome_grader)
      find("summary", text: "Optional model execution").click
      fill_in "Judge configuration JSON", with: "{unfinished"
      click_button "Save grader version"
      assert_selector "[role=alert]", text: /valid JSON/
      find("summary", text: "Optional model execution").click
      assert_field "Judge configuration JSON", with: "{unfinished"
      capture("configuration-error-390", 390)
      fill_in "Judge configuration JSON", with: judge_execution.to_json
      click_button "Save grader version"
      assert_text "Compiled cases keep their prior grader version"
      visit workspace_corpus_calibration_set_calibration_sample_path(@workspace, @corpus, @judge_set, sample)
      click_button "Request fixed judge"
      assert_selector "[role=alert]", text: /Confirm disclosure/
      assert_equal 0, CalibrationJudgeRun.where(corpus: @corpus).count
      find("input#judge_disclose").send_keys(:space)
      assert_selector "input#judge_disclose:checked"
      [ 1280, 390 ].each { |width| capture("calibration-consent-#{width}", width) }
      click_button "Request fixed judge"
      assert_text "Queued · one fixed attempt"
      calls = []
      with_judge_response(response: judge_response, calls:) { 2.times { CalibrationJudgeRunJob.perform_now(sample.reload.calibration_judge_run.id) } }
      assert_equal 1, calls.size
      click_link "Refresh judge state"
      assert_text "Complete · one fixed attempt"
      assert_no_selector "h2", text: "Machine prediction"
      select "Fail — breaks the requirement", from: "Your decision"
      fill_in "Evidence for your decision", with: "The response asks for expiry but does not identify it as a possible cause."
      click_button "Save expert label"
      assert_selector "h2", text: "Machine prediction"
      assert_text "endpoint_reported"
      [ 1280, 390 ].each { |width| capture("calibration-result-#{width}", width) }
      visit workspace_corpus_calibration_set_path(@workspace, @corpus, @judge_set)
      assert_text "1 true positives"
      assert_text "Do not tune on held-out samples"
      visit workspace_corpus_eval_suite_path(@workspace, @corpus, @suite)
      select "Recorded support fixture · v1 · scripted", from: "Target version"
      click_button "Start fixed run"
      assert_selector "[role=alert]", text: /Separately confirm/
      select "Recorded support fixture · v1 · scripted", from: "Target version"
      find("input#judge_disclose").send_keys(:space)
      assert_selector "input#judge_disclose:checked"
      [ 1280, 390 ].each { |width| capture("suite-consent-#{width}", width) }
      click_button "Start fixed run"
      assert_selector "h1", text: /Run/
      run = EvaluationRun.order(:id).last
      with_judge_response(response: judge_response) { EvaluationRunJob.perform_now(run.id) }
      click_link "Refresh run"
      click_link @scenario.current_version.title, match: :first
      assert_text "The output requests evidence but never identifies the possible cause"
      find("summary", text: "Judge evidence and execution record").click
      assert_text "test-judge-2026-09"
      assert_text "micro_units"
      assert_not_includes page.text, "test-only-token"
      [ 1280, 390 ].each { |width| capture("failure-evidence-#{width}", width) }
      regression = @corpus.eval_suites.create!(workspace: @workspace, name: "Diagnosis regressions", kind: "regression")
      visit workspace_corpus_evaluation_result_path(@workspace, @corpus, run.evaluation_results.sole)
      select regression.name, from: "Regression suite"
      fill_in "Why this failure must not return", with: "Collecting a diagnostic field alone must not satisfy diagnosis."
      click_button "Review and add regression"
      assert_selector "h1", text: regression.name
      assert_text "Collecting a diagnostic field alone"
      assert_equal [ @case.id ], regression.eval_cases.ids
    end
  end

  test "a revised judge compiles a new case and needs fresh held-out labels and separate consent" do
    build_judge_evaluation
    original_sample = judge_sample(cohort: "development")
    with_endpoint_approval do
      original_attempt = CalibrationJudgeRun.request!(sample: original_sample, membership: @membership, disclose: true)
      with_judge_response(response: judge_response) { CalibrationJudgeRunJob.perform_now(original_attempt.id) }
      original_sample.label!(membership: @membership, previous_id: nil, decision: "fail", rationale: "Synthetic expert: asking for expiry alone does not identify a cause.")
      original_history = original_sample.human_labels.map(&:attributes)
      original_prediction = original_sample.reload.calibration_prediction.attributes
      sign_in users(:owner)
      visit workspace_corpus_grader_path(@workspace, @corpus, @outcome_grader)
      fill_in "Company rubric", with: "#{@outcome_grader.current_version.definition.fetch('rubric')} An evidence request alone is not a diagnosis."
      fill_in "Judge abstention threshold", with: "0.95"
      click_button "Save grader version"
      assert_text "Compiled cases keep their prior grader version"
      revised = @outcome_grader.reload.current_version
      assert_equal 3, revised.number
      assert_equal 2, @case.eval_case_checks.find_by!(requirement_kind: "outcomes").grader_version.number
      visit workspace_corpus_calibration_set_path(@workspace, @corpus, @judge_set, cohort: "development")
      assert_selector "#fixed-report .judge-threshold", exact_text: "0.8"
      assert_text "not calibrated probability or accuracy"
      [ 1280, 390 ].each { |width| capture("fixed-threshold-#{width}", width) }

      visit new_workspace_corpus_eval_case_path(@workspace, @corpus, scenario_id: @scenario.id)
      @scenario.current_version.requirements.each do |kind, statements|
        statements.each_index do |index|
          grader = kind == "actions" ? @action_grader : @outcome_grader
          evidence = @case.eval_case_checks.find_by!(requirement_kind: kind, requirement_index: index).scenario_evidence
          select "#{grader.name} · v#{grader.current_version.number}", from: "Grader for #{kind} #{index + 1}"
          select "#{evidence.corpus_item.title} · #{evidence.kind}", from: "Source for #{kind} #{index + 1}"
        end
      end
      click_button "Compile fixed case"
      assert_text "Contract compiled with fixed graders"
      revised_case = @corpus.eval_cases.order(:id).last
      assert_not_equal @case.id, revised_case.id
      assert_equal @case.scenario_version_id, revised_case.scenario_version_id
      visit workspace_corpus_calibration_sets_path(@workspace, @corpus)
      fill_in "Set name", with: "Fresh revised diagnosis"
      select "#{@outcome_grader.name} · v3", from: "Fixed grader version"
      click_button "Create calibration set"
      assert_selector "h1", text: "Fresh revised diagnosis"
      assert_text "0 samples · 0 labelled · 0 compared"
      assert_text "Not enough evidence"
      fresh_set = @corpus.calibration_sets.find_by!(name: "Fresh revised diagnosis")
      assert_selector "#fixed-report .judge-threshold", exact_text: "0.95"
      [ 1280, 390 ].each { |width| capture("revision-empty-#{width}", width) }

      held_out_output = support_output(text: "Certificate expiry could be a cause. Please share the certificate expiry date.")
      click_link "Add output sample"
      select "Case #{revised_case.id} · Outcomes 1", from: "Case check"
      select "Held out — measure, do not tune", from: "Sample cohort"
      fill_in "Output JSON", with: held_out_output.to_json
      click_button "Add sample"
      assert_selector "h1", text: /Sample/
      fresh_sample = fresh_set.calibration_samples.sole
      assert_empty fresh_sample.human_labels
      assert_nil fresh_sample.calibration_prediction
      assert_no_selector "h2", text: "Machine prediction"
      assert_no_difference -> { CalibrationJudgeRun.count } do
        click_button "Request fixed judge"
        assert_selector "[role=alert]", text: /Confirm disclosure/
      end
      check "I approve sending this sample, rubric and company evidence to its fixed judge."
      click_button "Request fixed judge"
      assert_text "Queued · one fixed attempt"
      calls = []
      with_judge_response(response: judge_response(output: held_out_output, confidence: 0.99), calls:) do
        2.times { CalibrationJudgeRunJob.perform_now(fresh_sample.reload.calibration_judge_run.id) }
      end
      assert_equal 1, calls.size
      assert_includes JSON.parse(calls.sole.body).fetch("rubric"), "An evidence request alone is not a diagnosis."
      click_link "Refresh judge state"
      assert_no_selector "h2", text: "Machine prediction"
      assert_empty fresh_sample.human_labels
      [ 1280, 390 ].each { |width| capture("revision-blind-#{width}", width) }
      select "Pass — meets the requirement", from: "Your decision"
      fill_in "Evidence for your decision", with: "Synthetic expert: the response names expiry as a possible cause, not a confirmed diagnosis."
      click_button "Save expert label"
      assert_selector "h2", text: "Machine prediction"
      visit workspace_corpus_calibration_set_path(@workspace, @corpus, fresh_set)
      assert_text "Held out evidence · fixed v3"
      assert_text "1 false positives"
      assert_text "0 true positives"
      assert_equal [ 0, 1, 0, 0 ], CalibrationReport.call(set: fresh_set).values_at(:true_positive, :false_positive, :false_negative, :true_negative)
      [ 1280, 390 ].each { |width| capture("revision-held-out-#{width}", width) }
      assert_equal original_history, original_sample.reload.human_labels.map(&:attributes)
      assert_equal original_prediction, original_sample.reload.calibration_prediction.attributes
      assert_equal 1, CalibrationReport.call(set: @judge_set, cohort: "development")[:true_positive]
      assert_equal 0, CalibrationReport.call(set: @judge_set)[:samples]
      assert_equal 1, fresh_set.calibration_samples.count
    end
  end

  private
    def capture(name, width)
      page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width:, height: 1600, deviceScaleFactor: 2, mobile: false)
      assert_no_horizontal_overflow
      assert_no_csp_violations
      return unless ENV["CAPTURE_LAB_SCREENSHOTS"] == "1"
      path = Rails.root.join(".amp/in/artifacts/judge/#{name}.png")
      FileUtils.mkdir_p(path.dirname)
      page.execute_script("window.scrollTo(0, 0)")
      size = page.driver.browser.execute_cdp("Page.getLayoutMetrics").fetch("cssContentSize")
      image = page.driver.browser.execute_cdp("Page.captureScreenshot", captureBeyondViewport: true, clip: { x: 0, y: 0, width:, height: size.fetch("height"), scale: 1 })
      File.binwrite(path, Base64.decode64(image.fetch("data")))
    end
end
