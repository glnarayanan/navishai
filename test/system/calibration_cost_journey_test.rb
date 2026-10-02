require "application_system_test_case"
require_relative "../test_helpers/eval_test_helper"

class CalibrationCostJourneyTest < ApplicationSystemTestCase
  include EvalTestHelper

  test "expert repairs retained assumptions labels blindly and sees separate observed and empty costs" do
    build_eval_definitions
    item = compile_case
    sign_in users(:owner)
    visit workspace_corpus_calibration_sets_path(@workspace, @corpus)
    fill_in "Set name", with: "Fixture cost assumptions"
    select "Collect expiry evidence · v1", from: "Fixed grader version"
    assert_no_selector "details[open]"
    find("summary", text: "Optional error-cost assumptions").click
    fill_in "False-positive cost", with: "1e2"
    fill_in "False-negative cost", with: "7.5"
    fill_in "Common cost unit", with: "fixture units"
    fill_in "Error-cost rationale", with: "Synthetic assumptions for this fixed grader only."
    click_button "Create calibration set"
    assert_selector "#error-cost-repair", text: /plain decimal/
    assert_field "Set name", with: "Fixture cost assumptions"
    assert_field "False-positive cost", with: "1e2"
    assert_field "False-negative cost", with: "7.5"
    assert_field "Common cost unit", with: "fixture units"
    assert_field "Error-cost rationale", with: "Synthetic assumptions for this fixed grader only."
    inspect_sizes("retained-error")
    fill_in "False-positive cost", with: "1.25"
    click_button "Create calibration set"
    assert_selector "h1", text: "Fixture cost assumptions"
    assert_text "Unknown — no comparable certain labels"
    assert_text "Changing assumptions requires a new set"
    assert_text "expert ##{users(:owner).id}"
    set = CalibrationSet.order(:id).last
    assert_equal BigDecimal("1.25"), set.false_positive_cost
    assert_equal BigDecimal("7.5"), set.false_negative_cost
    inspect_sizes("empty")
    click_link "Add output sample"
    select "Case #{item.id} · Actions 1", from: "Case check"
    select "Held out — measure, do not tune", from: "Sample cohort"
    fill_in "Output JSON", with: JSON.pretty_generate(support_output(text: "Synthetic recorded answer."))
    click_button "Add sample"
    assert_selector "h2", text: "Expert judgment"
    assert_no_selector "h2", text: "Machine prediction"
    inspect_sizes("blind")
    select "Pass — meets the requirement", from: "Your decision"
    fill_in "Evidence for your decision", with: "Synthetic expert interpretation for the browser fixture."
    click_button "Save expert label"
    assert_selector "h2", text: "Machine prediction"
    click_link "Fixture cost assumptions"
    assert_selector "#fixed-report", text: /1 false positives/
    assert_selector "#fixed-report", text: /1.25 fixture units/
    assert_selector "#fixed-report", text: /not verified business costs/
    assert_equal BigDecimal("1.25"), set.reload.false_positive_cost
    inspect_sizes("labelled-report")
    click_link "Development"
    assert_selector "#fixed-report", text: /Unknown — no comparable certain labels/
    assert_text "0 samples · 0 labelled · 0 compared"
    assert_equal 1, set.calibration_samples.count
  end

  private
    def inspect_sizes(name)
      [ 1280, 390 ].each do |width|
        page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width:, height: 1000, deviceScaleFactor: 2, mobile: false)
        assert_no_horizontal_overflow
        assert_no_csp_violations
        next unless ENV["CAPTURE_LAB_SCREENSHOTS"] == "1"

        path = Rails.root.join(".amp/in/artifacts/calibration-costs/#{name}-#{width}.png")
        FileUtils.mkdir_p(path.dirname)
        page.execute_script("window.scrollTo(0, 0)")
        size = page.driver.browser.execute_cdp("Page.getLayoutMetrics").fetch("cssContentSize")
        image = page.driver.browser.execute_cdp("Page.captureScreenshot", captureBeyondViewport: true,
          clip: { x: 0, y: 0, width:, height: size.fetch("height"), scale: 1 })
        File.binwrite(path, Base64.decode64(image.fetch("data")))
      end
    end
end
