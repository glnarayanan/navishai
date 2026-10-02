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
