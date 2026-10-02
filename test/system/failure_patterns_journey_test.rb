require "application_system_test_case"
require_relative "../test_helpers/failure_patterns_test_helper"

class FailurePatternsJourneyTest < ApplicationSystemTestCase
  include FailurePatternsTestHelper

  test "expert inspects empty errors cross grader failures and mixed uncertainty without changing saved results" do
    build_failure_patterns
    queued = request_run
    errored = request_run
    with_scripted_call(->(**) { {} }) { EvaluationRunJob.perform_now(errored.id) }
    pure_case = compile_case(checks: @checks.map { |check| check["requirement_kind"] == "outcomes" ? check.merge("grader_version_id" => @action_grader.current_version_id) : check })
    pure_suite = @corpus.eval_suites.create!(workspace: @workspace, name: "Deterministic failure proof")
    pure_suite.add_case!(membership: @membership, case_id: pure_case.id)
    pure_run = request_run(suite: pure_suite)
    EvaluationRunJob.perform_now(pure_run.id)
    sign_in users(:owner)
    [ 1280, 390, 320 ].each do |width|
      resize_viewport(width)
      visit workspace_corpus_evaluation_run_path(@workspace, @corpus, queued)
      within "#failure-patterns" do
        assert_text "0 execution errors · 2 not executed"
        assert_text "No reported behavioural failures"
        assert_no_selector "[data-pattern-kind]"
      end
      capture("empty-#{width}")
      visit workspace_corpus_evaluation_run_path(@workspace, @corpus, errored)
      within "#failure-patterns" do
        assert_text "2 execution errors · 0 not executed"
        assert_no_selector "[data-pattern-kind]"
      end
      capture("errors-#{width}")
      visit workspace_corpus_evaluation_run_path(@workspace, @corpus, pure_run)
      within "#failure-patterns" do
        assert_selector "[data-pattern-kind=actions][data-pattern-type=tool_called]"
        assert_selector "[data-pattern-kind=outcomes][data-pattern-type=tool_called]"
        assert_no_selector "[data-unresolved-check-id]"
        find("[data-pattern-kind=actions] [data-failed-check-id] summary", match: :first).send_keys(:enter)
        assert_text "Collect expiry."
        assert_text "Not applicable: deterministic condition, not a probability."
      end
      capture("failure-#{width}")
      visit workspace_corpus_evaluation_run_path(@workspace, @corpus, @mixed_run)
      within "#failure-patterns" do
        assert_text "4 failed checks across 2 fixed cases · 3 grader versions"
        assert_selector "[data-pattern-kind]", count: 5
        assert_selector "[data-unresolved-check-id]", count: 4, visible: :all
        assert_text "Broad requirement-kind group"
        find("[data-pattern-kind=outcomes] [data-failed-check-id] summary", match: :first).send_keys(:enter)
        assert_text "0.94 · fixed abstention threshold 0.8"
        find("[data-pattern-kind=outcomes] summary", text: "Fixed check definition and saved decision", match: :first).send_keys(:enter)
        assert_text '"reference": "target_output"'
        assert_text "1 abstentions · 1 judge errors"
      end
      capture("mixed-failure-#{width}")
      result = @mixed_run.evaluation_results.find_by!(eval_case: @case)
      within "#failure-uncertainty-#{result.id}" do
        all("[data-unresolved-check-id] > summary").each { |summary| summary.send_keys(:enter) }
        assert_text "0.32 · fixed abstention threshold 0.8"
        assert_text "Not supplied · fixed abstention threshold 0.8"
        assert_text "Judge request failed; remote outcome unknown."
      end
      capture("mixed-uncertainty-#{width}")
      assert_no_difference [ "EvaluationResult.count", "AuditEvent.count", "RegressionCase.count" ] do
        click_link "Refresh run"
        assert_selector "#failure-patterns"
        assert_selector "[data-failed-check-id]", count: 12, visible: :all
      end
    end
    visit workspace_corpus_evaluation_run_path(@workspace, @corpus, @mixed_run)
    find("[data-pattern-kind=actions] [data-failed-check-id] summary", match: :first).send_keys(:enter)
    click_link "Inspect failed result ##{@mixed_run.evaluation_results.find_by!(eval_case: @case).id} and regression review", match: :first
    assert_text "Retain a regression"
    assert_text "tool_called: condition not met"
    assert_no_horizontal_overflow
    assert_no_csp_violations
  end

  private
    def resize_viewport(width)
      page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
      page.current_window.resize_to(width, 1000)
      page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width:, height: 1000, deviceScaleFactor: 2, mobile: false)
      Selenium::WebDriver::Wait.new(timeout: Capybara.default_max_wait_time).until { page.evaluate_script("window.innerWidth") == width }
      assert_equal width, page.evaluate_script("window.innerWidth")
      assert_equal 2, page.evaluate_script("window.devicePixelRatio")
    end

    def capture(name)
      assert_no_horizontal_overflow
      assert_no_csp_violations
      return unless ENV["CAPTURE_LAB_SCREENSHOTS"] == "1"

      path = Rails.root.join(".amp/in/artifacts/failure-patterns/#{name}.png")
      FileUtils.mkdir_p(path.dirname)
      page.execute_script("window.scrollTo({ top: 0, left: 0, behavior: 'instant' })")
      Selenium::WebDriver::Wait.new(timeout: Capybara.default_max_wait_time).until { page.evaluate_script("window.scrollY") == 0 }
      size = page.driver.browser.execute_cdp("Page.getLayoutMetrics").fetch("cssContentSize")
      image = page.driver.browser.execute_cdp("Page.captureScreenshot", captureBeyondViewport: true,
        clip: { x: 0, y: 0, width: page.evaluate_script("window.innerWidth"), height: size.fetch("height"), scale: 1 })
      File.binwrite(path, Base64.decode64(image.fetch("data")))
    end
end
