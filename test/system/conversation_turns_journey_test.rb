require "application_system_test_case"
require_relative "../test_helpers/evaluation_test_helper"
require_relative "../test_helpers/http_target_test_helper"

class ConversationTurnsJourneyTest < ApplicationSystemTestCase
  include EvaluationTestHelper
  include HttpTargetTestHelper

  test "expert retains plan errors reviews new version and confirms fixed delayed disclosure" do
    build_evaluation
    sign_in users(:owner)
    visit workspace_corpus_scenario_path(@workspace, @corpus, @scenario)
    fill_in "Expert follow-ups (JSON array)", with: "[{broken"
    click_button "Save new version"
    assert_selector "[role=alert]", text: /follow-ups.*valid JSON/
    assert_field "Expert follow-ups (JSON array)", with: "[{broken"
    capture_states("error")
    plan = [ { "after_assistant_contains" => "expiry", "message" => "It expired yesterday." } ]
    fill_in "Expert follow-ups (JSON array)", with: plan.to_json
    click_button "Save new version"
    assert_text "Version saved. This version needs expert review."
    @scenario.reload
    assert_equal plan, @scenario.current_version.follow_ups
    assert_not @scenario.current_version.approved?
    @scenario.review!(membership: @membership, version_id: @scenario.current_version_id, decision: "approve", note: "Engineering fixture only: checked against source playbook.")
    checks = @checks.map { |check| check.merge("scenario_evidence_id" => @scenario.current_version.scenario_evidence.find_by!(kind: "expectation").id) }
    fixed = compile_case(checks:)
    @suite.eval_suite_cases.delete_all(:delete_all)
    @suite.add_case!(membership: @membership, case_id: fixed.id)
    with_endpoint_approval do
      target = EvaluationTarget.define!(corpus: @corpus, membership: @membership, name: "Incremental fixture", adapter: "http_conversation", configuration: { "endpoint" => HTTP_ENDPOINT })
      visit workspace_corpus_eval_case_path(@workspace, @corpus, fixed)
      assert_text "Fixed conversation plan · maximum 2 calls"
      capture_states("case")
      visit workspace_corpus_eval_suite_path(@workspace, @corpus, @suite)
      find("summary", text: "planned follow-up disclosure").click
      assert_text "It expired yesterday."
      assert_text "actual transcript forwarding"
      select "#{target.name} · v1 · http_conversation", from: "Target version"
      capture_states("disclosure")
      check "I approve sending visible inputs to the selected HTTP endpoint for this run."
      click_button "Start fixed run"
      assert_text "Queued"
      run = @corpus.evaluation_runs.order(:id).last
      requests = []
      with_test_method(EvaluationHttp, :call, ->(**args) { requests << args.deep_dup; support_output(text: "Expiry date please.") }) do
        2.times { EvaluationRunJob.perform_now(run.id) }
      end
      assert_equal 2, requests.size
      assert_not_includes requests.first.to_json, "It expired yesterday."
      assert_includes requests.last.to_json, "It expired yesterday."
      assert_not_includes requests.to_json, "private answer"
      visit workspace_corpus_evaluation_result_path(@workspace, @corpus, run.evaluation_results.sole)
      assert_text "It expired yesterday."
      capture_states("result")
    end
  end

  private
    def capture_states(name)
      [ 1280, 390 ].each do |width|
        page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width:, height: 1600, deviceScaleFactor: 2, mobile: false)
        assert_no_horizontal_overflow
        assert_no_csp_violations
        next unless ENV["CAPTURE_LAB_SCREENSHOTS"] == "1"

        path = Rails.root.join(".amp/in/artifacts/conversation-turns/#{name}-#{width}.png")
        FileUtils.mkdir_p(path.dirname)
        page.execute_script("window.scrollTo(0, 0)")
        size = page.driver.browser.execute_cdp("Page.getLayoutMetrics").fetch("cssContentSize")
        image = page.driver.browser.execute_cdp("Page.captureScreenshot", captureBeyondViewport: true, clip: { x: 0, y: 0, width: size.fetch("width"), height: size.fetch("height"), scale: 1 })
        File.binwrite(path, Base64.decode64(image.fetch("data")))
      end
    end
end
