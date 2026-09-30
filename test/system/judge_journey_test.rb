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

  private
    def capture(name, width)
      page.current_window.resize_to(width, 1600)
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
