require "application_system_test_case"
require_relative "../test_helpers/recorded_evaluation_test_helper"

class RecordedReplayJourneyTest < ApplicationSystemTestCase
  include RecordedEvaluationTestHelper
  include ActiveJob::TestHelper

  test "expert and viewer page every exact match on a fixed historical trace without writes" do
    build_recorded_evaluation
    matches = compile_replay_history(situations: [ @trace["input"]["situation"] ] * 50)
    changed = @trace.merge("target_version" => "later-fixture", "input" => @trace["input"].merge("situation" => "A different later input."))
    newer = CorpusIntake.call(corpus: @corpus, membership: @membership, name: @snapshot.source.name, kind: "traces", bytes: [ changed ].to_json)
    assert_equal 2, newer.number
    sign_in users(:owner)
    path = workspace_corpus_source_path(@workspace, @corpus, @snapshot.source, snapshot: 1, matching_item_id: @trace_item.id,
      matching_page: 1, dependency_page: 2, case_page: 2, decision_page: 3)
    selector = "#replay-cases-#{@trace_item.id}"
    assert_no_difference [ "AuditEvent.count", "EvaluationRun.count", "ScenarioVersion.count", "HumanLabel.count", "TraceScenarioDecision.count" ] do
      assert_no_enqueued_jobs do
        visit path
        within(selector) do
          assert_selector "summary", text: "Cases with identical visible input (51)"
          assert_selector "ul li", count: 50
          find_link("Next matching cases").send_keys(:enter)
        end
        assert_selector "#{selector}[open] p", text: "Page 2 · up to 50 exact matches"
        assert_selector "#{selector} ul li", count: 1
        assert_link "Case #{matches.last.id} · Replay fixture case 50"
        query = Rack::Utils.parse_query(URI.parse(page.current_url).query)
        assert_equal %w[1 2 2 3 2], query.values_at("snapshot", "dependency_page", "case_page", "decision_page", "matching_page")
        [ 1280, 390 ].each { |width| capture("matching-page-#{width}", width, selector:) }
        page.refresh
        assert_selector "#{selector}[open] p", text: "Page 2 · up to 50 exact matches"
        assert_selector "#{selector} ul li", count: 1
        within(selector) { click_link "Previous matching cases" }
        assert_selector "#{selector}[open] p", text: "Page 1 · up to 50 exact matches"
        assert_selector "#{selector} ul li", count: 50
        visit workspace_corpus_source_path(@workspace, @corpus, @snapshot.source, snapshot: 1, matching_item_id: @trace_item.id, matching_page: 9999)
        assert_selector "#{selector}[open]", text: "No matching cases on this page."
        [ 1280, 390 ].each { |width| capture("matching-recovery-#{width}", width, selector:) }
        within(selector) { click_link "First matching page" }
        assert_selector "#{selector}[open] p", text: "Page 1 · up to 50 exact matches"
        assert_selector "#{selector} ul li", count: 50
      end
    end
    Membership.create!(workspace: @workspace, user: users(:teammate), role: :viewer)
    find(".lab-navigation summary").click
    click_button "Sign out"
    sign_in users(:teammate)
    assert_no_difference [ "AuditEvent.count", "EvaluationRun.count", "ScenarioVersion.count", "HumanLabel.count" ] do
      assert_no_enqueued_jobs do
        visit path
        within(selector) { click_link "Next matching cases" }
        assert_selector "#{selector}[open] p", text: "Page 2 · up to 50 exact matches"
        assert_link "Case #{matches.last.id} · Replay fixture case 50"
        assert_no_link "Define recorded target from this trace"
        assert_no_button "Propose scenario from trace"
        assert_no_button "Append trace decision"
        assert_no_horizontal_overflow
        assert_no_csp_violations
      end
    end
  end

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
    def capture(name, width, selector: nil)
      page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width:, height: 1000, deviceScaleFactor: 2, mobile: false)
      assert_no_horizontal_overflow
      assert_no_csp_violations
      return unless ENV["CAPTURE_LAB_SCREENSHOTS"] == "1"
      path = Rails.root.join(".amp/in/artifacts/recorded-replay/#{name}.png")
      FileUtils.mkdir_p(path.dirname)
      page.execute_script("window.scrollTo(0, 0)")
      size = page.driver.browser.execute_cdp("Page.getLayoutMetrics").fetch("cssContentSize")
      clip = { x: 0, y: 0, width:, height: size.fetch("height"), scale: 1 }
      if selector
        bounds = page.evaluate_script("(() => { const rect = document.querySelector(#{selector.to_json}).getBoundingClientRect(); return { top: rect.top + window.scrollY, bottom: rect.bottom + window.scrollY }; })()")
        clip[:y] = [ bounds.fetch("top") - 12, 0 ].max.floor
        clip[:height] = (bounds.fetch("bottom") - clip[:y] + 16).ceil
      end
      image = page.driver.browser.execute_cdp("Page.captureScreenshot", captureBeyondViewport: true, clip:)
      File.binwrite(path, Base64.decode64(image.fetch("data")))
    end
end
