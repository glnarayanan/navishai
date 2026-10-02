require "application_system_test_case"
require_relative "../test_helpers/eval_test_helper"

class CalibrationJourneyTest < ApplicationSystemTestCase
  include EvalTestHelper

  test "expert uploads held out output labels blindly corrects a decision and sees measured disagreement" do
    build_eval_definitions
    item = compile_case
    sign_in users(:owner)
    visit workspace_corpus_calibration_sets_path(@workspace, @corpus)
    assert_text "No calibration sets yet"
    fill_in "Set name", with: "SSO diagnostic gate"
    select "Collect expiry evidence · v1", from: "Fixed grader version"
    click_button "Create calibration set"
    assert_selector "h1", text: "SSO diagnostic gate"
    assert_text "Not enough evidence"
    click_link "Add output sample"
    select "Case #{item.id} · Actions 1", from: "Case check"
    select "Held out — measure, do not tune", from: "Sample cohort"
    fill_in "Output JSON", with: "{unfinished"
    click_button "Add sample"
    assert_selector "[role=alert]", text: /valid JSON/
    assert_field "Output JSON", with: "{unfinished"
    page.current_window.resize_to(390, 1600)
    capture("upload-error-390")
    fill_in "Output JSON", with: JSON.pretty_generate(support_output(text: "I have reset your SSO configuration. Try again."))
    click_button "Add sample"
    assert_selector "h2", text: "Expert judgment"
    assert_no_selector "h2", text: "Machine prediction"
    capture("blind-390")
    sample_path = page.current_path
    click_link "Supporting source snapshot"
    assert_selector "h1", text: "Support export"
    assert_includes page.current_url, "#record-"
    assert_text "Request the expiry date before changing configuration."
    visit sample_path
    assert_no_selector "h2", text: "Machine prediction"
    select "Pass — meets the requirement", from: "Your decision"
    fill_in "Evidence for your decision", with: "Initial judgment; I overlooked the missing diagnostic request."
    click_button "Save expert label"
    assert_selector "h2", text: "Machine prediction"
    sample_path = page.current_path
    [ 1280, 390 ].each do |width|
      page.current_window.resize_to(width, 1600)
      assert_no_horizontal_overflow
      assert_no_csp_violations
      capture("labelled-#{width}")
    end
    click_link "SSO diagnostic gate"
    assert_text "1 false positives"
    assert_text "100.0%"
    [ 1280, 390 ].each do |width|
      page.current_window.resize_to(width, 1600)
      assert_no_horizontal_overflow
      assert_no_csp_violations
      capture("report-#{width}")
    end
    visit sample_path
    select "Fail — breaks the requirement", from: "Your decision"
    fill_in "Evidence for your decision", with: "The source requires collecting expiry before configuration changes."
    click_button "Save expert label"
    assert_text "Expert label saved. Prior labels remain in history."
    assert_field "Evidence for your decision", with: "The source requires collecting expiry before configuration changes."
    click_link "SSO diagnostic gate"
    assert_text "1 true positives"
    assert_text "0 false positives"
    click_link "Development"
    assert_text "0 samples · 0 labelled · 0 compared"
  end

  test "cohort accounting shows overlapping prediction states without treating them as ground truth" do
    build_eval_definitions
    item = compile_case
    set = CalibrationSet.define!(corpus: @corpus, membership: @membership, name: "Incomplete judge evidence", grader_version_id: @outcome_grader.current_version_id)
    other = Membership.create!(workspace: @workspace, user: users(:teammate), role: :member)
    check = item.eval_case_checks.find_by!(requirement_kind: "outcomes")
    [ [ "abstain", [ "fail", "pass" ] ], [ nil, [ "uncertain" ] ], [ "error", [] ],
      [ "abstain", [ "fail" ] ], [ nil, [ "pass" ] ], [ "pass", [ "fail" ] ] ].each_with_index do |(prediction, labels), index|
      sample = set.add_sample!(membership: @membership, check_id: check.id, cohort: "held_out", output: support_output(text: "Authored overlap #{index}"))
      sample.create_calibration_prediction!(workspace: @workspace, corpus: @corpus, result: { "decision" => prediction, "reason" => "Authored prediction" }, processing_version: "test-judge-v1", created_at: Time.current) if prediction
      labels.each_with_index do |decision, author|
        sample.label!(membership: author.zero? ? @membership : other, previous_id: nil, decision:, rationale: "Authored expert evidence, not a customer label.")
      end
    end
    sign_in users(:owner)
    [ "held_out", "development" ].each do |cohort|
      visit workspace_corpus_calibration_set_path(@workspace, @corpus, set, cohort:)
      within "#fixed-report" do
        if cohort == "held_out"
          assert_text "6 samples · 5 labelled · 1 compared"
          assert_selector ".calibration-exclusions", text: "1 unlabelled, 1 disputed, 1 uncertain; then, among certain labelled samples, 1 abstained and 1 without a usable prediction"
          assert_selector ".calibration-predictions", text: "1 pass, 0 fail, 2 abstain, 1 error and 2 missing"
          assert_selector "td", text: "1 false negatives"
        else
          assert_text "0 samples · 0 labelled · 0 compared"
          assert_selector ".calibration-exclusions", text: "0 unlabelled, 0 disputed, 0 uncertain"
          assert_selector ".calibration-predictions", text: "0 pass, 0 fail, 0 abstain, 0 error and 0 missing"
          assert_text "Not enough evidence"
        end
        assert_text "These totals overlap the exclusion reasons"
        assert_text "Disputed or uncertain samples cannot supply ground truth"
      end
      [ 1280, 390 ].each do |width|
        page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width:, height: 1000, deviceScaleFactor: 2, mobile: false)
        assert_no_horizontal_overflow
        assert_no_csp_violations
        capture("accounting-#{cohort}-#{width}")
      end
    end
    assert_equal 6, set.calibration_samples.count
    assert_equal 6, set.calibration_samples.joins(:human_labels).count
    assert_equal 4, set.calibration_samples.joins(:calibration_prediction).count
  end

  private
    def capture(name)
      return unless ENV["CAPTURE_LAB_SCREENSHOTS"] == "1"

      path = Rails.root.join(".amp/in/artifacts/calibration/#{name}.png")
      FileUtils.mkdir_p(path.dirname)
      page.execute_script("window.scrollTo(0, 0)")
      size = page.driver.browser.execute_cdp("Page.getLayoutMetrics").fetch("cssContentSize")
      width = [ size.fetch("width"), page.evaluate_script("window.innerWidth") ].max
      image = page.driver.browser.execute_cdp("Page.captureScreenshot", captureBeyondViewport: true, clip: { x: 0, y: 0, width:, height: size.fetch("height"), scale: 1 })
      File.binwrite(path, Base64.decode64(image.fetch("data")))
    end
end
