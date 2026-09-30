require "application_system_test_case"
require_relative "../test_helpers/recorded_evaluation_test_helper"

class RecordedReplayJourneyTest < ApplicationSystemTestCase
  include RecordedEvaluationTestHelper

  test "expert matches a trace grades its fixed output and admits a regression" do
    build_recorded_evaluation
    sign_in users(:owner)
    visit workspace_corpus_source_path(@workspace, @corpus, @snapshot.source)
    find("summary", text: "Cases with identical visible input").click
    assert_link "Case #{@case.id} · SSO certificate rotation"
    [ 1280, 390 ].each { |width| capture("matching-#{width}", width) }
    click_link "Define recorded target from this trace"
    fill_in "Target name", with: "Replay browser fixture"
    fill_in "Trace record ID (recorded only)", with: @knowledge.id
    click_button "Create target"
    assert_selector "[role=alert]", text: /unexpired production trace/
    assert_field "Target name", with: "Replay browser fixture"
    assert_field "Trace record ID (recorded only)", with: @knowledge.id.to_s
    capture("target-error-390", 390)
    fill_in "Trace record ID (recorded only)", with: @trace_item.id
    click_button "Create target"
    assert_selector "h1", text: "Replay browser fixture"
    assert_text "Recorded output, not a new agent execution"
    assert_link "Trace record #{@trace_item.id}"
    capture("definition-390", 390)
    visit workspace_corpus_eval_suite_path(@workspace, @corpus, @suite)
    select "Replay browser fixture · v1 · recorded", from: "Target version"
    click_button "Start fixed run"
    assert_selector "h1", text: /Run/
    run = EvaluationRun.order(:id).last
    EvaluationRunJob.perform_now(run.id)
    click_link "Refresh run"
    assert_text "Recorded production output replay, not a new agent execution"
    click_link @scenario.current_version.title, match: :first
    assert_text "Fail · Outcomes"
    assert_text "Fail · Actions"
    assert_link "the fixed production trace"
    [ 1280, 390 ].each { |width| capture("failure-#{width}", width) }
    result_path = page.current_path
    regression = @corpus.eval_suites.create!(workspace: @workspace, name: "Production trace regressions", kind: "regression")
    visit result_path
    select "Production trace regressions", from: "Regression suite"
    fill_in "Why this failure must not return", with: "The recorded agent skipped certificate evidence and claimed an unconfirmed change."
    click_button "Review and add regression"
    assert_selector "h1", text: "Production trace regressions"
    assert_equal @case.id, regression.eval_cases.sole.id
    assert_equal @membership.user_id, RegressionCase.find_by!(eval_suite: regression).reviewed_by_id
    capture("regression-390", 390)
  end

  private
    def capture(name, width)
      page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width:, height: 1000, deviceScaleFactor: 2, mobile: false)
      assert_no_horizontal_overflow
      assert_no_csp_violations
      return unless ENV["CAPTURE_LAB_SCREENSHOTS"] == "1"
      path = Rails.root.join(".amp/in/artifacts/recorded-replay/#{name}.png")
      FileUtils.mkdir_p(path.dirname)
      page.execute_script("window.scrollTo(0, 0)")
      size = page.driver.browser.execute_cdp("Page.getLayoutMetrics").fetch("cssContentSize")
      image = page.driver.browser.execute_cdp("Page.captureScreenshot", captureBeyondViewport: true, clip: { x: 0, y: 0, width:, height: size.fetch("height"), scale: 1 })
      File.binwrite(path, Base64.decode64(image.fetch("data")))
    end
end
