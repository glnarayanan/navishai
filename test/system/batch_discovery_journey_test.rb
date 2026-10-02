require "application_system_test_case"
require_relative "../test_helpers/batch_discovery_test_helper"

class BatchDiscoveryJourneyTest < ApplicationSystemTestCase
  include BatchDiscoveryTestHelper

  test "expert consents to all batches reviews receipts merges labels and mines unapproved minority candidate" do
    build_batch_corpus
    sign_in users(:owner)
    visit workspace_corpus_path(@workspace, @corpus)
    click_link "Bounded multi-request discovery"
    assert_text "2 discovery requests + 1 reducer"
    fill_in "Model configuration (JSON)", with: "{broken"
    click_button "Request model discovery"
    assert_selector "[role=alert]", text: /valid JSON/
    capture("configuration-error", 390)
    fill_in "Model configuration (JSON)", with: discovery_configuration.to_json
    fill_in "Model candidate limit", with: 2
    with_corpus_approval do
      click_button "Request model discovery"
      assert_selector "[role=alert]", text: /Confirm disclosure/
      find("#source-record-preview > summary").click
      find("details.source-record summary", text: "Repeated delivery").click
      assert_text "Webhook retries repeated a delete event and caused data loss."
      find("#source-record-preview > summary").click
      find("input#corpus_disclose").send_keys(:space)
      assert_selector "input#corpus_disclose:checked"
      [ 1280, 390 ].each { |width| capture("disclosure", width) }
      assert_operator page.evaluate_script("document.querySelector('[aria-labelledby=disclosure-preview]').getBoundingClientRect().bottom"), :<=,
        page.evaluate_script("document.querySelector('input#corpus_disclose').getBoundingClientRect().top")
      click_button "Request model discovery"
      assert_selector "h1", text: "Corpus analysis"
      assert_text "Queued · support-corpus-batch-v1"
      [ 1280, 390 ].each { |width| capture("queued", width) }
      analysis = CorpusAnalysis.where(corpus: @corpus).sole
      calls = []
      with_batch_responses(calls:) { 2.times { CorpusAnalysisJob.perform_now(analysis.id) } }
      click_link "Refresh result"
      assert_text "2 candidates selected from 106 conversations"
      assert_text "Destructive delivery"
      assert_equal 3, calls.size
      [ 1280, 390 ].each { |width| capture("proposal", width) }
      first("input[name=label]").set("Expert identity lifecycle")
      first("input[value='Save expert label']").click
      assert_text "expert revision 1"
      click_button "Create selected scenarios"
      assert_selector "h1", text: "Scenarios"
      click_link "Destructive replay", exact: true
      assert_field "Issue family", with: "Destructive delivery"
      assert_text "needs review"
      assert_not Scenario.find_by!(corpus: @corpus, corpus_item: @items.fetch("rare")).current_version.approved?
      [ 1280, 390 ].each { |width| capture("minority-review", width) }
    end
  end

  test "retained abstain error and interrupted states expose no partial mining" do
    build_batch_corpus
    sign_in users(:owner)
    [ "abstain", "error" ].each do |decision|
      mutation = ->(value, _) do
        decision == "abstain" ? value.merge!("decision" => "abstain", "clusters" => [], "candidates" => []) : value.merge!("schema" => "invalid")
      end
      with_batch_responses(change: mutation) do
        analysis = request_batch_analysis
        CorpusAnalysisJob.perform_now(analysis.id)
        visit workspace_corpus_corpus_analysis_path(@workspace, @corpus, analysis)
        assert_selector "h2", text: decision.humanize, exact_text: true
        assert_no_button "Create selected scenarios"
        assert_selector "details.source-record summary", text: "Not sent — attempt stopped", count: 2
        [ 1280, 390 ].each { |width| capture(decision, width) }
      end
    end
    with_corpus_approval do
      analysis = request_batch_analysis
      visit workspace_corpus_corpus_analysis_path(@workspace, @corpus, analysis)
      click_button "Interrupt analysis attempt"
      assert_text "Expert interrupted this attempt"
      assert_no_button "Create selected scenarios"
      assert_selector "details.source-record summary", text: "Not sent — attempt stopped", count: 3
      capture("interrupted", 390)
    end
  end

  private
    def capture(name, width)
      page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width:, height: 1100, deviceScaleFactor: 2, mobile: false)
      assert_no_horizontal_overflow
      assert_no_csp_violations
      return unless ENV["CAPTURE_LAB_SCREENSHOTS"] == "1"
      path = Rails.root.join(".amp/in/artifacts/batch-discovery/#{name}-#{width}.png")
      FileUtils.mkdir_p(path.dirname)
      page.execute_script("window.scrollTo(0, 0)")
      height = page.evaluate_script("document.documentElement.scrollHeight")
      image = page.driver.browser.execute_cdp("Page.captureScreenshot", captureBeyondViewport: true, clip: { x: 0, y: 0, width:, height:, scale: 1 })
      File.binwrite(path, Base64.decode64(image.fetch("data")))
    end
end
