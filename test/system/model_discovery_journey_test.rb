require "application_system_test_case"
require_relative "../test_helpers/model_discovery_test_helper"

class ModelDiscoveryJourneyTest < ApplicationSystemTestCase
  include ModelDiscoveryTestHelper

  test "expert reviews exact corpus disclosure and source-backed families before mining unapproved scenarios" do
    build_discovery_corpus
    sign_in users(:owner)
    visit workspace_corpus_path(@workspace, @corpus)
    click_link "Model-assisted corpus discovery"
    assert_selector "h1", text: "Model corpus discovery"
    fill_in "Model configuration (JSON)", with: "{incomplete"
    click_button "Request model discovery"
    assert_selector "[role=alert]", text: /valid JSON/
    assert_field "Model configuration (JSON)", with: "{incomplete"
    capture("configuration-error-390", 390)
    fill_in "Model configuration (JSON)", with: discovery_configuration.to_json
    fill_in "Model candidate limit", with: 2
    with_corpus_approval do
      click_button "Request model discovery"
      assert_selector "[role=alert]", text: /Confirm disclosure/
      assert_equal 0, CorpusAnalysis.where(corpus: @corpus).count
      find("details.source-record summary", text: "Federation rejected").click
      assert_text "Federation assertion rejected after trust bundle refresh."
      find("input#corpus_disclose").send_keys(:space)
      assert_selector "input#corpus_disclose:checked"
      [ 1280, 390 ].each { |width| capture("disclosure-#{width}", width) }
      click_button "Request model discovery"
      assert_selector "h1", text: "Corpus analysis"
      assert_text "Queued · support-corpus-v1"
      capture("queued-390", 390)
      analysis = CorpusAnalysis.where(corpus: @corpus).sole
      calls = []
      with_discovery_response(calls:) { 2.times { CorpusAnalysisJob.perform_now(analysis.id) } }
      click_link "Refresh result"
      assert_text "2 candidates selected from 3 conversations"
      assert_text "No expert label or scenario approval comes from this analysis."
      first("details.source-record summary").click
      assert_selector "h3", text: "Membership quote"
      assert_text "Represent the shared signing-material family"
      assert_not_includes page.text, "test-only-corpus-token"
      [ 1280, 390 ].each { |width| capture("result-#{width}", width) }
      assert_equal 1, calls.size
      assert_equal 0, HumanLabel.where(corpus: @corpus).count
      first("input[name=label]").set("Expert's signing-material family")
      first("input[value='Save expert label']").click
      assert_text "expert revision 1"
      click_button "Create selected scenarios"
      assert_selector "h1", text: "Scenarios"
      click_link "Signing-material diagnostics", exact: true
      assert_field "Customer starting situation", with: "Enterprise SSO stopped after the signing certificate changed."
      assert_field "Actions — one requirement per line", with: "Collect the signing certificate expiry before changing configuration."
      assert_field "Issue family", with: "Expert's signing-material family"
      assert_text "needs review"
      assert_not Scenario.find_by!(corpus: @corpus, corpus_item: @items.fetch("login")).current_version.approved?
    end
  end

  test "empty input abstention and execution error provide honest recovery without scenarios" do
    build_discovery_corpus
    sign_in users(:owner)
    empty = @workspace.corpora.create!(name: "Empty discovery fixture")
    visit new_workspace_corpus_corpus_analysis_path(@workspace, empty)
    assert_text "Add conversations or use a smaller corpus"
    assert_no_button "Request model discovery"
    capture("empty-390", 390)
    response = discovery_response.merge("decision" => "abstain", "reason" => "Synthetic fixture: no sound company taxonomy yet.", "clusters" => [], "candidates" => [])
    with_discovery_response(response:) do
      analysis = request_model_analysis
      CorpusAnalysisJob.perform_now(analysis.id)
      visit workspace_corpus_corpus_analysis_path(@workspace, @corpus, analysis)
      assert_selector "h2", text: "Abstain"
      assert_no_button "Create selected scenarios"
      capture("abstain-390", 390)
    end
    with_discovery_response(response: { "schema" => "invalid" }) do
      analysis = request_model_analysis
      CorpusAnalysisJob.perform_now(analysis.id)
      visit workspace_corpus_corpus_analysis_path(@workspace, @corpus, analysis)
      assert_selector "h2", text: "Error"
      assert_text "Error · attempt complete · support-corpus-v1"
      assert_no_text "Complete · support-corpus-v1"
      assert_text "Remote outcome/cost may be unknown"
      assert_no_button "Create selected scenarios"
      capture("error-390", 390)
    end
    assert_equal 0, Scenario.where(corpus: @corpus).count
  end

  test "oversized context blocks previews and fixed history without a partial form and keeps a recovery path" do
    build_discovery_corpus
    add_large_context_sources
    analysis = build_fixed_analysis(complete: true)
    sign_in users(:owner)
    visit new_workspace_corpus_corpus_analysis_path(@workspace, @corpus, processing_method: "model_batch")
    assert_selector "[role=status]", text: /10 MiB.*context JSON/
    assert_no_button "Request model discovery"
    assert_no_selector "input#corpus_disclose"
    [ 1280, 390 ].each { |width| capture("oversized-preview-#{width}", width) }
    visit workspace_corpus_corpus_analysis_path(@workspace, @corpus, analysis)
    assert_selector "[role=alert]", text: /10 MiB.*context JSON/
    assert_text "No partial source preview or candidates are shown."
    assert_no_button "Create selected scenarios"
    assert_no_selector "details.source-record"
    click_link "Refresh result"
    assert_selector "[role=alert]", text: /10 MiB/
    [ 1280, 390 ].each { |width| capture("oversized-history-#{width}", width) }
    find("a", text: "Return to the corpus", exact_text: true).send_keys(:enter)
    assert_selector "h1", text: @corpus.name
    assert_equal "complete", analysis.reload.state
    assert_equal 0, Scenario.where(corpus: @corpus).count
  end

  private
    def capture(name, width)
      page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width:, height: 1100, deviceScaleFactor: 2, mobile: false)
      assert_no_horizontal_overflow
      assert_no_csp_violations
      return unless ENV["CAPTURE_LAB_SCREENSHOTS"] == "1"
      path = Rails.root.join(".amp/in/artifacts/model-discovery/#{name}.png")
      FileUtils.mkdir_p(path.dirname)
      page.execute_script("window.scrollTo(0, 0)")
      height = page.evaluate_script("document.documentElement.scrollHeight")
      image = page.driver.browser.execute_cdp("Page.captureScreenshot", captureBeyondViewport: true, clip: { x: 0, y: 0, width:, height:, scale: 1 })
      File.binwrite(path, Base64.decode64(image.fetch("data")))
    end
end
