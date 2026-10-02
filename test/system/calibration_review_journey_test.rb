require "application_system_test_case"
require_relative "../test_helpers/eval_test_helper"

class CalibrationReviewJourneyTest < ApplicationSystemTestCase
  include EvalTestHelper

  test "expert filters review work labels a blind sample and sees refreshed disputes without changing cohort metrics" do
    build_eval_definitions
    fixed = compile_case
    check = fixed.eval_case_checks.find_by!(requirement_kind: "actions")
    set = CalibrationSet.define!(corpus: @corpus, membership: @membership, name: "SSO expert review fixture", grader_version_id: @action_grader.current_version_id)
    other = Membership.create!(workspace: @workspace, user: users(:teammate), role: :member)
    samples = {}
    [ [ "aligned", true, "pass" ], [ "disagreement", true, "fail" ], [ "uncertain", false, "uncertain" ], [ "disputed", false, "fail" ], [ "unlabelled", true, nil ] ].each do |state, called, decision|
      sample = set.add_sample!(membership: @membership, check_id: check.id, cohort: "held_out", output: support_output(text: "Review fixture #{state}.", tools: called ? [ "collect_expiry" ] : []))
      sample.label!(membership: @membership, previous_id: nil, decision:, rationale: "Fixture expert judgment: #{decision}.") if decision
      samples[state] = sample
    end
    [ "disputed", "unlabelled" ].each do |state|
      samples.fetch(state).label!(membership: other, previous_id: nil, decision: "pass", rationale: "Other expert rationale must stay hidden before the first label.")
    end
    sign_in users(:owner)
    visit workspace_corpus_calibration_set_path(@workspace, @corpus, set)
    assert_selector "h1", text: set.name
    within "#review-samples" do
      assert_selector "li", count: 5
      assert_equal %w[unlabelled disputed uncertain disagreement aligned], all("li").map { |entry| entry["data-review-state"] }
      assert_no_text "Other expert rationale"
    end
    [ 1280, 390 ].each { |width| capture("queue-#{width}", width) }
    select "Experts disagree (1)", from: "Review focus"
    find("input[value='Filter review samples']").send_keys(:enter)
    assert_selector "#review-samples [role=status]", text: "1 of 5 cohort samples shown."
    assert_selector "#review-samples li[data-review-state=disputed]", count: 1
    assert_text "5 samples · 5 labelled · 3 compared"
    page.refresh
    assert_select "Review focus", selected: "Experts disagree (1)"
    capture("disputed-390", 390)
    click_link "Clear review focus"
    click_link "Start next unlabelled review"
    assert_selector "h1", text: "Sample #{samples.fetch('unlabelled').id}"
    assert_no_selector "h2", text: "Machine prediction"
    assert_no_text "Other expert rationale"
    select "Fail — breaks the requirement", from: "Your decision"
    fill_in "Evidence for your decision", with: "Fixture expert: the reported tool did not request enough diagnostic evidence."
    click_button "Save expert label"
    assert_text "Expert label saved. Prior labels remain in history."
    assert_selector "h2", text: "Machine prediction"
    assert_text "Other expert rationale"
    click_link set.name
    assert_select "Review focus", options: [ "All samples", "Needs your label (0)", "Experts disagree (2)", "Expert uncertainty (1)", "Machine / expert disagreement (1)", "No usable prediction (0)", "Machine / experts agree (1)" ]
    select "Needs your label (0)", from: "Review focus"
    click_button "Filter review samples"
    assert_selector "#review-samples [role=status]", text: "0 of 5 cohort samples shown."
    assert_text "No samples need this review focus."
    assert_no_link "Start next unlabelled review"
    capture("empty-390", 390)
    click_link "Clear review focus"
    assert_selector "#review-samples li", count: 5
    click_link "Development"
    assert_text "0 samples · 0 labelled · 0 compared"
    assert_select "Review focus", selected: "All samples"
    assert_text "No samples in this cohort."
  end

  private
    def capture(name, width)
      page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width:, height: 1000, deviceScaleFactor: 2, mobile: false)
      assert_no_horizontal_overflow
      assert_no_csp_violations
      return unless ENV["CAPTURE_LAB_SCREENSHOTS"] == "1"

      path = Rails.root.join(".amp/in/artifacts/calibration-review/#{name}.png")
      FileUtils.mkdir_p(path.dirname)
      page.execute_script("window.scrollTo(0, 0)")
      size = page.driver.browser.execute_cdp("Page.getLayoutMetrics").fetch("cssContentSize")
      image = page.driver.browser.execute_cdp("Page.captureScreenshot", captureBeyondViewport: true, clip: { x: 0, y: 0, width:, height: size.fetch("height"), scale: 1 })
      File.binwrite(path, Base64.decode64(image.fetch("data")))
    end
end
