require "application_system_test_case"
require_relative "../test_helpers/evaluation_test_helper"

class ResultCalibrationJourneyTest < ApplicationSystemTestCase
  include EvaluationTestHelper

  test "expert selects fixed result explicitly chooses cohort and labels before provenance reveals judgments" do
    build_evaluation
    run = request_run
    EvaluationRunJob.perform_now(run.id)
    result = run.evaluation_results.sole
    check = @case.eval_case_checks.find_by!(requirement_kind: "actions")
    set = CalibrationSet.define!(corpus: @corpus, membership: @membership, name: "Selected runtime failures", grader_version_id: @action_grader.current_version_id)
    sign_in users(:owner)
    visit workspace_corpus_evaluation_result_path(@workspace, @corpus, result)
    assert_text "Add this saved output to calibration"
    assert_text "Selected failures can bias held-out measurement"
    [ 1280, 390 ].each { |width| capture("live-selection-#{width}", width) }
    click_link "Select #{set.name} · #{@action_grader.name} v1"
    assert_selector "h2", text: "Fixed retained output"
    assert_no_field "Output JSON"
    assert_selector "select[name=cohort] option:checked", text: "Choose a cohort"
    select "Case #{@case.id} · Actions 1", from: "Case check"
    select "Development — tune here", from: "Sample cohort"
    [ 1280, 390 ].each { |width| capture("live-fixed-form-#{width}", width) }
    # A concurrent legitimate manual intake must not silently acquire result provenance.
    manual = set.add_sample!(membership: @membership, check_id: check.id, cohort: "development", output: result.output)
    click_button "Add sample"
    assert_selector "[role=alert]", text: /different provenance/
    assert_selector "select[name=cohort] option:checked", text: "Development — tune here"
    assert_no_field "Output JSON"
    capture("live-retained-error-390", 390)
    assert_nil manual.reload.evaluation_result_id
    # A new expert-chosen set is independent of that immutable manual sample.
    fresh = CalibrationSet.define!(corpus: @corpus, membership: @membership, name: "Saved runtime outputs", grader_version_id: @action_grader.current_version_id)
    visit new_workspace_corpus_calibration_set_calibration_sample_path(@workspace, @corpus, fresh, evaluation_result_id: result.id)
    select "Case #{@case.id} · Actions 1", from: "Case check"
    select "Development — tune here", from: "Sample cohort"
    click_button "Add sample"
    assert_text "Fixed sample saved"
    assert_text "Saved result ##{result.id} · fixed case ##{@case.id}"
    assert_no_link "Exact saved result"
    assert_no_link "Source run"
    assert_no_selector "h2", text: "Machine prediction"
    [ 1280, 390 ].each { |width| capture("live-blind-#{width}", width) }
    select "Fail — breaks the requirement", from: "Your decision"
    fill_in "Evidence for your decision", with: "The fixed company policy requires expiry evidence; this recorded output has no collection call."
    click_button "Save expert label"
    assert_text "Expert label saved"
    assert_link "Exact saved result", href: workspace_corpus_evaluation_result_path(@workspace, @corpus, result)
    assert_link "Source run", href: workspace_corpus_evaluation_run_path(@workspace, @corpus, run)
    assert_selector "h2", text: "Machine prediction"
    [ 1280, 390 ].each { |width| capture("live-revealed-#{width}", width) }
    assert_equal result.id, fresh.calibration_samples.sole.evaluation_result_id
    assert_equal "development", fresh.calibration_samples.sole.cohort
    assert_equal 1, fresh.calibration_samples.sole.human_labels.count
  end

  private
    def capture(name, width)
      page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width:, height: 1000, deviceScaleFactor: 2, mobile: false)
      assert_no_horizontal_overflow
      assert_no_csp_violations
      return unless ENV["CAPTURE_LAB_SCREENSHOTS"] == "1"

      path = Rails.root.join(".amp/in/artifacts/result-calibration/#{name}.png")
      FileUtils.mkdir_p(path.dirname)
      page.execute_script("window.scrollTo(0, 0)")
      size = page.driver.browser.execute_cdp("Page.getLayoutMetrics").fetch("cssContentSize")
      image = page.driver.browser.execute_cdp("Page.captureScreenshot", captureBeyondViewport: true, clip: { x: 0, y: 0, width:, height: size.fetch("height"), scale: 1 })
      File.binwrite(path, Base64.decode64(image.fetch("data")))
    end
end
