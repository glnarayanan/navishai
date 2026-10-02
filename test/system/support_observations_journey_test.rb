require "application_system_test_case"
require_relative "../test_helpers/batch_discovery_test_helper"

class SupportObservationsJourneyTest < ApplicationSystemTestCase
  include BatchDiscoveryTestHelper

  test "explicit batch v2 repair consent and review keep every source anchor independent of selection" do
    build_batch_corpus
    sign_in users(:owner)
    visit workspace_corpus_path(@workspace, @corpus)
    click_link "Batch support observations"
    assert_text "source-backed support observations · v2"
    assert_text "2 discovery requests + 1 reducer"
    assert_text "cannot create a new relationship between records in different batches"
    fill_in "Model configuration (JSON)", with: "{broken"
    click_button "Request model discovery"
    assert_selector "[role=alert]", text: /valid JSON/
    assert_selector "input[name=processing_method][value=model_batch_observations]", visible: :all
    capture("repair", 390)
    fill_in "Model configuration (JSON)", with: discovery_configuration.to_json
    fill_in "Model candidate limit", with: 2
    with_corpus_approval do
      click_button "Request model discovery"
      assert_selector "[role=alert]", text: /Confirm disclosure/
      assert_no_selector "input#corpus_disclose:checked"
      find("input#corpus_disclose").send_keys(:space)
      [ 1280, 390 ].each { |width| capture("preview", width) }
      click_button "Request model discovery"
      assert_text "Queued · support-corpus-batch-v2"
    end
    analysis = @corpus.corpus_analyses.sole
    calls = []
    with_batch_responses(calls:) { 2.times { CorpusAnalysisJob.perform_now(analysis.id) } }
    click_link "Refresh result"
    assert_text "Source-backed support observations"
    assert_equal 3, calls.size
    assert_selector "#support-observations details", count: 2
    all("#support-observations > details > summary").each { |summary| summary.send_keys(:enter) }
    within "#support-observations" do
      assert_text "Evidence sufficiency · Proposed", count: 2
      assert_text "Uncertainty", count: 2
      assert_text "do not prove a cause, correct escalation or resolution", count: 2
      assert_selector "article", count: 4
      assert_text "record identity-98"
      assert_text "record rare"
      assert_text "Escalate repeated deletes with data loss to Engineering.", count: 2
      assert_no_button "Approve"
    end
    [ 1280, 390 ].each { |width| capture("result", width, selector: "#support-observations") }
    within "#support-observations" do
      click_link "History · snapshot 2 · record identity-98"
    end
    assert_selector "#record-#{@items.fetch('identity-98').id}"
    assert_text "Snapshot 2"
    assert_equal 0, Scenario.count
    assert_equal 0, HumanLabel.count
  end

  test "empty discovery and stopped reducer keep unknowns separate from published global observations" do
    build_batch_corpus
    sign_in users(:owner)
    [ "empty", "stopped" ].each do |state|
      calls = []
      with_batch_responses(calls:, change: ->(response, payload) do
        if state == "empty" && payload["schema"] == ModelCorpusDiscovery::OBSERVATIONS_VERSION
          response["observations"] = []
        elsif state == "stopped" && payload["schema"] == BatchCorpusDiscovery::MERGE_OBSERVATIONS_VERSION
          response.merge!("decision" => "abstain", "families" => [], "candidate_refs" => [], "observation_refs" => [])
        end
      end) do
        analysis = request_batch_analysis(processing_method: "model_batch_observations")
        CorpusAnalysisJob.perform_now(analysis.id)
        visit workspace_corpus_corpus_analysis_path(@workspace, @corpus, analysis)
        if state == "empty"
          assert_selector "#support-observations [role=status]", text: "No observations retained. This does not establish that no support issue exists."
          assert_no_selector "#support-observations details"
        else
          assert_text "No global support observations published"
          assert_no_selector "#support-observations"
          assert_no_button "Create selected scenarios"
        end
        [ 1280, 390 ].each { |width| capture(state, width) }
        click_link "Refresh result"
        assert_equal 3, calls.size
      end
    end
  end

  private
    def capture(name, width, selector: "main")
      page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width:, height: 1100, deviceScaleFactor: 2, mobile: false)
      assert_equal width, page.evaluate_script("window.innerWidth")
      assert_no_horizontal_overflow
      assert_no_csp_violations
      return unless ENV["CAPTURE_LAB_SCREENSHOTS"] == "1"
      bounds = page.evaluate_script("(() => { const r = document.querySelector('#{selector}').getBoundingClientRect(); return { y: r.top + window.scrollY, height: r.height }; })()")
      image = page.driver.browser.execute_cdp("Page.captureScreenshot", captureBeyondViewport: true,
        clip: { x: 0, y: bounds.fetch("y"), width:, height: bounds.fetch("height"), scale: 1 })
      path = Rails.root.join(".amp/in/artifacts/support-observations/#{name}-#{width}.png")
      FileUtils.mkdir_p(path.dirname)
      File.binwrite(path, Base64.decode64(image.fetch("data")))
    end
end
