require "application_system_test_case"
require_relative "../test_helpers/evaluation_test_helper"

class EvaluationJourneyTest < ApplicationSystemTestCase
  include EvaluationTestHelper

  test "expert runs fixed cases inspects a source backed failure and keeps a regression for a corrected target" do
    build_evaluation
    @outcome_grader.revise!(membership: @membership, version_id: @outcome_grader.current_version_id, kind: "deterministic", definition: { "type" => "text_contains", "value" => "certificate expiry" })
    checks = @checks.map { |check| check["requirement_kind"] == "outcomes" ? check.merge("grader_version_id" => @outcome_grader.current_version_id) : check }
    @case = compile_case(checks:)
    @suite.eval_suite_cases.delete_all(:delete_all)
    @suite.add_case!(membership: @membership, case_id: @case.id)
    sign_in users(:owner)
    visit workspace_corpus_evaluation_targets_path(@workspace, @corpus)
    fill_in "Target name", with: "New scripted proof"
    fill_in "Script configuration JSON", with: "{unfinished"
    click_button "Create scripted target"
    assert_selector "[role=alert]", text: /valid JSON/
    assert_field "Script configuration JSON", with: "{unfinished"
    page.current_window.resize_to(390, 1600)
    capture("target-error-390")
    visit workspace_corpus_eval_suite_path(@workspace, @corpus, @suite)
    select "SSO fixture · v1 · scripted", from: "Target version"
    click_button "Start fixed run"
    assert_selector "h1", text: /Run/
    assert_text "Waiting for the evaluation worker"
    run = EvaluationRun.order(:id).last
    EvaluationRunJob.perform_now(run.id)
    click_link "Refresh run"
    assert_text "Complete"
    assert_text "Failure patterns"
    click_link @scenario.current_version.title, match: :first
    assert_text "Fail · Outcomes"
    assert_text "tool_called: condition not met"
    assert_link "Supporting source snapshot", count: 2
    [ 1280, 390 ].each do |width|
      page.current_window.resize_to(width, 1600)
      assert_no_horizontal_overflow
      assert_no_csp_violations
      capture("failure-#{width}")
    end
    result_path = page.current_path
    click_link "Create a regression suite"
    fill_in "Suite name", with: "Certificate regressions"
    select "Regression", from: "Suite purpose"
    click_button "Create suite"
    assert_selector "h1", text: "Certificate regressions"
    visit result_path
    select "Certificate regressions", from: "Regression suite"
    fill_in "Why this failure must not return", with: "Collect certificate evidence before claiming configuration changes."
    click_button "Review and add regression"
    assert_selector "h1", text: "Certificate regressions"
    assert_text "Collect certificate evidence before claiming configuration changes."
    [ 1280, 390 ].each do |width|
      page.current_window.resize_to(width, 1600)
      assert_no_horizontal_overflow
      assert_no_csp_violations
      capture("regression-#{width}")
    end
    suite_path = page.current_path
    visit workspace_corpus_evaluation_target_path(@workspace, @corpus, @target)
    fill_in "Script configuration JSON", with: JSON.pretty_generate(script_configuration(output: support_output(tools: [ "collect_expiry" ])))
    click_button "Save target version"
    assert_text "version 2"
    visit suite_path
    select "SSO fixture · v2 · scripted", from: "Target version"
    click_button "Start fixed run"
    assert_selector "h1", text: /Run/
    EvaluationRunJob.perform_now(EvaluationRun.order(:id).last.id)
    click_link "Refresh run"
    assert_text "Complete"
    assert_text "Pass"
    assert_text "No reported behavioural failures"
    capture("passed-390")
    visit result_path
    assert_text "Fail · Outcomes"
    click_link "Supporting source snapshot", match: :first
    find("summary", text: "Delete this source").click
    assert_text "targets, runs, results and regressions"
    assert_no_horizontal_overflow
    capture("deletion-warning-390")
    find(".lab-navigation summary").click
    click_button "Sign out"
    visit root_path
    assert_text "Local scripted runs can retain failures as regressions."
    assert_no_horizontal_overflow
    capture("home-390")
  end

  private
    def capture(name)
      return unless ENV["CAPTURE_LAB_SCREENSHOTS"] == "1"

      path = Rails.root.join(".amp/in/artifacts/evaluation/#{name}.png")
      FileUtils.mkdir_p(path.dirname)
      page.execute_script("window.scrollTo(0, 0)")
      size = page.driver.browser.execute_cdp("Page.getLayoutMetrics").fetch("cssContentSize")
      width = [ size.fetch("width"), page.evaluate_script("window.innerWidth") ].max
      image = page.driver.browser.execute_cdp("Page.captureScreenshot", captureBeyondViewport: true, clip: { x: 0, y: 0, width:, height: size.fetch("height"), scale: 1 })
      File.binwrite(path, Base64.decode64(image.fetch("data")))
    end
end
