require "application_system_test_case"
require_relative "../test_helpers/relationship_discovery_test_helper"

class CrossBatchRelationshipsJourneyTest < ApplicationSystemTestCase
  include RelationshipDiscoveryTestHelper

  test "explicit v3 repair consent and keyboard review show new relationships and every original quote" do
    build_relationship_corpus
    sign_in users(:owner)
    visit workspace_corpus_path(@workspace, @corpus)
    click_link "Cross-batch support relationships"
    assert_text "cross-batch support relationships · v3"
    assert_text "2 discovery requests + 1 reducer"
    assert_text "Only retained observation quotes"
    fill_in "Model configuration (JSON)", with: "{broken"
    click_button "Request model discovery"
    assert_selector "[role=alert]", text: /valid JSON/
    assert_selector "input[name=processing_method][value=model_batch_relationships]", visible: :all
    capture("repair", 390, selector: "#main-content")
    fill_in "Model configuration (JSON)", with: discovery_configuration.to_json
    fill_in "Model candidate limit", with: 2
    with_corpus_approval do
      click_button "Request model discovery"
      assert_selector "[role=alert]", text: /Confirm disclosure/
      assert_no_selector "input#corpus_disclose:checked"
      find("input#corpus_disclose").send_keys(:space)
      [ 1280, 390 ].each { |width| capture("preview", width) }
      click_button "Request model discovery"
      assert_text "Queued · support-corpus-batch-v3"
    end
    analysis = @corpus.corpus_analyses.sole
    calls = []
    with_relationship_responses(calls:) { 2.times { CorpusAnalysisJob.perform_now(analysis.id) } }
    click_link "Refresh result"
    assert_selector "#support-relationships details", count: 1
    find("#support-relationships summary").send_keys(:enter)
    within "#support-relationships" do
      assert_text "Contradictory guidance · Proposed"
      assert_text "Different account scope or dates may explain these reports"
      assert_selector "article", count: 2
      assert_text "Agent: Rotate first, then collect expiry."
      assert_text "Playbook: Collect expiry before rotation."
      assert_text "evidence index 0", count: 2
      assert_no_button "Approve"
    end
    assert_selector "#support-observations details", count: 2
    all("#support-observations > details > summary").each { |summary| summary.send_keys(:enter) }
    within "#support-observations" do
      assert_selector "article", count: 4
      assert_text "Request the signing certificate expiry", count: 2
      assert_text "All original observations remain unchanged"
    end
    [ 1280, 390, 320 ].each { |width| capture("result", width, selector: "#support-relationships") }
    [ 1280, 390 ].each { |width| capture("originals", width, selector: "#support-observations") }
    visit workspace_corpus_corpus_analysis_path(@workspace, @corpus, analysis)
    assert_equal 3, calls.size
    find("#support-relationships summary").send_keys(:enter)
    within "#support-relationships" do
      click_link "History · snapshot 2 · record report-99"
    end
    assert_selector "#record-#{@items.fetch('report-99').id}"
    assert_text "Snapshot 2"
    assert_equal [ 0, 0 ], [ Scenario.count, HumanLabel.count ]
  end

  test "no relationships and stopped reduction show distinct uncertainty without resend or partial findings" do
    build_relationship_corpus
    sign_in users(:owner)
    [ "empty", "stopped" ].each do |state|
      calls = []
      with_relationship_responses(calls:, change: ->(response, payload) do
        if payload["schema"] == BatchCorpusDiscovery::MERGE_RELATIONSHIPS_VERSION
          response["relationships"] = []
          response.merge!("decision" => "abstain", "families" => [], "candidate_refs" => [], "observation_refs" => []) if state == "stopped"
        end
      end) do
        analysis = request_relationship_analysis
        CorpusAnalysisJob.perform_now(analysis.id)
        visit workspace_corpus_corpus_analysis_path(@workspace, @corpus, analysis)
        if state == "empty"
          assert_selector "#support-relationships [role=status]", text: /No cross-batch relationships proposed/
          assert_no_selector "#support-relationships details"
          assert_selector "#support-observations details", count: 2
        else
          assert_text "No global support relationships published"
          assert_no_selector "#support-relationships"
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
      path = Rails.root.join(".amp/in/artifacts/cross-batch-relationships/#{name}-#{width}.png")
      FileUtils.mkdir_p(path.dirname)
      File.binwrite(path, Base64.decode64(image.fetch("data")))
    end
end
