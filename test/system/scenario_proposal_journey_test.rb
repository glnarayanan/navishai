require "application_system_test_case"
require_relative "../test_helpers/scenario_proposal_test_helper"

class ScenarioProposalJourneyTest < ApplicationSystemTestCase
  include ScenarioProposalTestHelper

  test "expert inspects disclosure and fixed quoted suggestions without changing a scenario or label" do
    build_proposal_scenario
    sign_in users(:owner)
    visit workspace_corpus_scenario_path(@workspace, @corpus, @scenario)
    find("#model-proposal summary", text: "Model scenario proposal", exact_text: true).click
    fill_in "Model configuration (JSON)", with: "{incomplete"
    click_button "Request model proposal"
    assert_selector "[role=alert]", text: /valid JSON/
    assert_field "Model configuration (JSON)", with: "{incomplete"
    capture("configuration-error-390", 390)
    fill_in "Model configuration (JSON)", with: proposal_configuration.to_json
    with_scenario_approval do
      click_button "Request model proposal"
      assert_selector "[role=alert]", text: /Confirm disclosure/
      assert_equal 0, ScenarioProposal.where(corpus: @corpus).count
      find("input#proposal_disclose").send_keys(:space)
      assert_selector "input#proposal_disclose:checked"
      [ 1280, 390 ].each { |width| capture("disclosure-#{width}", width) }
      counts = [ ScenarioVersion.count, ScenarioReview.count, HumanLabel.count ]
      click_button "Request model proposal"
      assert_text "Queued · fixed version"
      capture("queued-390", 390)
      proposal = ScenarioProposal.where(corpus: @corpus).sole
      calls = []
      with_proposal_response(calls:) { 2.times { ScenarioProposalJob.perform_now(proposal.id) } }
      click_link "Refresh proposal state"
      assert_text "Complete · fixed version"
      assert_selector "h3", text: "Requirement evidence"
      assert_text "Collect the certificate expiry date before changing configuration."
      assert_field "Title", with: @version.title
      assert_equal counts, [ ScenarioVersion.count, ScenarioReview.count, HumanLabel.count ]
      assert_equal @version.id, @scenario.reload.current_version_id
      assert_equal 1, calls.size
      assert_not_includes page.text, "test-only-scenario-token"
      [ 1280, 390 ].each { |width| capture("proposal-#{width}", width) }
      click_link "Inspect quoted source", match: :first
      assert_selector "h1", text: "Support export"
      assert_text "Snapshot 1"
      assert_text "Engineering escalation if valid metadata returns 500."
      visit workspace_corpus_scenario_path(@workspace, @corpus, @scenario)
      fill_in "Title", with: "Expert's corrected scenario"
      click_button "Save new version"
      assert_selector ".flash-notice", text: "Version saved. This version needs expert review."
      assert_field "Title", with: "Expert's corrected scenario"
      assert_not @scenario.reload.current_version.approved?
      click_link "Version #{@version.number}", exact: true
      assert_selector "h3", text: "Requirement evidence"
      assert_equal @version.id, ScenarioProposal.where(corpus: @corpus).sole.scenario_version_id
    end
  end

  test "abstention and unknown execution outcome remain inspectable without authoritative changes" do
    build_proposal_scenario
    sign_in users(:owner)
    response = proposal_response.merge("decision" => "abstain", "reason" => "Synthetic fixture: sources do not establish an expected resolution.", "scenario" => nil, "evidence_links" => [])
    with_proposal_response(response:) do
      proposal = request_proposal
      ScenarioProposalJob.perform_now(proposal.id)
    end
    visit workspace_corpus_scenario_path(@workspace, @corpus, @scenario)
    assert_selector "h2", text: "Abstain"
    assert_no_selector "h3", text: "Suggested definition"
    capture("abstain-390", 390)
    @scenario.revise!(membership: @membership, base_version_id: @version.id, attributes: { title: "Deliberate second fixture version" })
    @version = @scenario.reload.current_version
    with_proposal_response(response: { "schema" => "invalid" }) do
      proposal = request_proposal
      ScenarioProposalJob.perform_now(proposal.id)
    end
    visit workspace_corpus_scenario_path(@workspace, @corpus, @scenario)
    assert_selector "h2", text: "Error"
    assert_text "remote outcome/cost may be unknown"
    assert_no_button "Request model proposal"
    assert_equal 0, ScenarioReview.where(corpus: @corpus).count
    capture("error-390", 390)
  end

  private
    def capture(name, width)
      page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width:, height: 1100, deviceScaleFactor: 2, mobile: false)
      assert_no_horizontal_overflow
      assert_no_csp_violations
      return unless ENV["CAPTURE_LAB_SCREENSHOTS"] == "1"
      path = Rails.root.join(".amp/in/artifacts/scenario-proposals/#{name}.png")
      FileUtils.mkdir_p(path.dirname)
      page.execute_script("window.scrollTo(0, 0)")
      height = page.evaluate_script("document.querySelector('#model-proposal').getBoundingClientRect().bottom + window.scrollY + 24")
      image = page.driver.browser.execute_cdp("Page.captureScreenshot", captureBeyondViewport: true, clip: { x: 0, y: 0, width:, height:, scale: 1 })
      File.binwrite(path, Base64.decode64(image.fetch("data")))
    end
end
