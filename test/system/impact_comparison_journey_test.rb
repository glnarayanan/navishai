require "application_system_test_case"
require_relative "../test_helpers/recorded_evaluation_test_helper"

class ImpactComparisonJourneyTest < ApplicationSystemTestCase
  include RecordedEvaluationTestHelper

  test "expert compares fixed runs inspects unresolved and changed definitions then follows stale policy dependencies" do
    build_compared_evaluation
    assert_equal "fail", @before.evaluation_results.sole.status
    assert_equal "pass", @after.evaluation_results.sole.status
    sign_in users(:owner)
    visit workspace_corpus_evaluation_run_path(@workspace, @corpus, @after)
    select "Run #{@before.id} · target #{@target.id} v1 · recorded", from: "Baseline run (before)"
    assert_no_difference [ "EvaluationRun.count", "EvaluationResult.count" ] do
      find("input[value='Compare saved runs']").send_keys(:enter)
      assert_selector "[data-change=recovery]", text: "Reported recovery"
    end
    assert_link "Before result: Fail", href: workspace_corpus_evaluation_result_path(@workspace, @corpus, @before.evaluation_results.sole)
    assert_link "After result: Pass", href: workspace_corpus_evaluation_result_path(@workspace, @corpus, @after.evaluation_results.sole)
    [ 1280, 390 ].each { |width| capture("recovery-#{width}", width) }
    click_link "Refresh run"
    assert_selector "[data-change=recovery]"
    visit workspace_corpus_evaluation_run_path(@workspace, @corpus, @before, baseline_id: @after.id)
    assert_selector "[data-change=regression]", text: "Reported regression"
    capture("regression-390", 390)

    queued = request_run
    visit workspace_corpus_evaluation_run_path(@workspace, @corpus, @after, baseline_id: queued.id)
    assert_selector "[data-change=unresolved]", text: "Not executed; no result."
    assert_no_selector "[data-change=recovery]"
    capture("unresolved-390", 390)

    different = compile_case(checks: @checks.map { |check| check.merge("grader_version_id" => @outcome_grader.current_version_id) })
    suite = @corpus.eval_suites.create!(workspace: @workspace, name: "Different grader definition")
    suite.add_case!(membership: @membership, case_id: different.id)
    changed_run = request_run(suite:)
    EvaluationRunJob.perform_now(changed_run.id)
    visit workspace_corpus_evaluation_run_path(@workspace, @corpus, changed_run, baseline_id: @before.id)
    assert_selector "[data-change=unmatched]", count: 2
    assert_no_selector "[data-change=recovery]"
    find("summary", text: "After frozen visible input").click
    find("summary", text: "Before frozen visible input").click
    capture("unmatched-390", 390)

    @scenario.revise!(membership: @membership, base_version_id: @scenario.current_version_id, attributes: { title: "Review the new SSO policy" })
    source = @knowledge.source_snapshot.source
    CorpusIntake.call(corpus: @corpus, membership: @membership, name: source.name, kind: "document", bytes: "New policy: request current IdP metadata before changing configuration.")
    visit workspace_corpus_source_path(@workspace, @corpus, source)
    assert_text "Snapshot 2"
    within "#source-impact" do
      assert_text "Historical scenario version"
      assert_text "Current scenario version"
      assert_selector "strong", text: "Stale document evidence", count: 2
      assert_link @suite.name
      assert_link "Case #{@case.id} · SSO certificate rotation — recorded failure fixture · v2"
    end
    [ 1280, 390 ].each { |width| capture("policy-impact-#{width}", width) }
    click_link "Snapshot 1"
    assert_text "Never claim a change without a confirmed action."
    within "#source-impact" do
      click_link "SSO certificate rotation — recorded failure fixture · v2"
    end
    assert_selector "h1", text: "SSO certificate rotation"
    assert_selector "[role=status]", text: "A linked source changed."
  end

  private
    def capture(name, width)
      page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width:, height: 1000, deviceScaleFactor: 2, mobile: false)
      assert_no_horizontal_overflow
      assert_no_csp_violations
      return unless ENV["CAPTURE_LAB_SCREENSHOTS"] == "1"
      path = Rails.root.join(".amp/in/artifacts/impact-comparisons/#{name}.png")
      FileUtils.mkdir_p(path.dirname)
      page.execute_script("window.scrollTo(0, 0)")
      size = page.driver.browser.execute_cdp("Page.getLayoutMetrics").fetch("cssContentSize")
      image = page.driver.browser.execute_cdp("Page.captureScreenshot", captureBeyondViewport: true, clip: { x: 0, y: 0, width:, height: size.fetch("height"), scale: 1 })
      File.binwrite(path, Base64.decode64(image.fetch("data")))
    end
end
