require "application_system_test_case"
require_relative "../test_helpers/assumption_impact_test_helper"

class AssumptionImpactJourneyTest < ApplicationSystemTestCase
  include AssumptionImpactTestHelper

  test "expert previews unlinked assumptions confirms one request inspects quotes and separately revises" do
    build_change_impact
    sign_in users(:owner)
    visit workspace_corpus_path(@workspace, @corpus)
    click_link "Source changes"
    assert_selector "nav[aria-label='Corpus sections'] a[aria-current=page]", text: "Source changes"
    assert_text "No attempts on this page"
    click_link "Preview a document change"
    click_link "Product entitlement · source ##{@source.id}"
    find("summary", text: "Find document source and snapshot IDs").send_keys(:enter)
    assert_text "ID #{@before.id} · snapshot 1"
    fill_in "Before snapshot ID", with: @before.id
    fill_in "After snapshot ID", with: @after.id
    fill_in "Scenario IDs (spaces or commas)", with: @scenarios.map(&:id).join(", ")
    click_button "Preview fixed change"
    assert_selector "h2", text: "Fixed comparison and local provenance"
    assert_text "Only Enterprise plans support SAML."
    assert_text "Business and Enterprise plans support SAML."
    within "#impact-preview" do
      find("summary", text: @version.title).send_keys(:enter)
      assert_text "Business excludes SAML"
      assert_text "Treat Business SAML as unsupported."
      all("details").each do |detail|
        detail.find("summary").send_keys(:enter) unless detail.matches_css?("[open]")
      end
      assert_text @before.digest
      assert_text @after.mask_digest
    end
    fill_in "Model configuration (JSON)", with: impact_configuration.to_json
    assert_no_field "impact_disclose"
    assert_no_button "Request change analysis"
    click_button "Preview exact model request"
    assert_selector "#impact-wire"
    assert_equal 0, AssumptionImpact.where(corpus: @corpus).count
    assert_selector "h3", text: "Exact model request"
    find("summary", text: "Inspect complete JSON request body").send_keys(:enter)
    wire = page.evaluate_script("document.querySelector('#impact-wire pre').textContent")
    assert_equal %w[content context title], JSON.parse(wire).fetch("input").fetch("before").keys.sort
    assert_unchecked_field "impact_disclose"
    [ 1280, 390 ].each { |width| capture("preview-#{width}", width) }
    fill_in "Model configuration (JSON)", with: "{broken"
    click_button "Preview exact model request"
    assert_selector "[role=alert]", text: /valid JSON/
    assert_field "Model configuration (JSON)", with: "{broken"
    assert_no_field "impact_disclose"
    [ 1280, 390 ].each { |width| capture("repair-#{width}", width) }
    fill_in "Model configuration (JSON)", with: impact_configuration.to_json
    click_button "Preview exact model request"
    with_impact_approval do
      click_button "Request change analysis"
      assert_selector "[role=alert]", text: /Confirm disclosure/
      assert_equal 0, AssumptionImpact.where(corpus: @corpus).count
      find("input#impact_disclose").send_keys(:space)
      assert_checked_field "impact_disclose"
      before = [ ScenarioVersion.count, ScenarioReview.count, HumanLabel.count ]
      click_button "Request change analysis"
      assert_selector "[role=status]", text: /Queued/
      [ 1280, 390 ].each { |width| capture("queued-#{width}", width) }
      impact = AssumptionImpact.where(corpus: @corpus).sole
      calls = []
      with_impact_response(calls:) { 2.times { AssumptionImpactJob.perform_now(impact.id) } }
      click_link "Refresh attempt state"
      assert_selector "h2", text: "Proposal"
      assert_text "Possibly affected requirements"
      assert_text "An expert must check rollout dates and account exceptions"
      assert_equal 1, calls.size
      assert_equal wire, calls.sole.body
      assert_equal wire, page.evaluate_script("document.querySelector('#impact-wire pre').textContent")
      assert_equal before, [ ScenarioVersion.count, ScenarioReview.count, HumanLabel.count ]
      assert_empty @source.dependent_versions
      assert @version.approved?
      assert_not @version.stale?
      assert_no_button "Request change analysis"
      assert_not_includes page.text, "test-only-impact-token"
      [ 1280, 390 ].each { |width| capture("proposal-#{width}", width) }
      find("a", text: "Open current version for separate revision and review").send_keys(:enter)
      assert_field "Title", with: @version.title
      assert_field "Outcomes — one requirement per line", with: "Treat Business SAML as unsupported."
      fill_in "Outcomes — one requirement per line", with: "Check this Business account's current SAML entitlement."
      click_button "Save new version"
      assert_text "Version saved. This version needs expert review."
      assert_not @scenario.reload.current_version.approved?
      visit workspace_corpus_assumption_impact_path(@workspace, @corpus, impact)
      assert_text "This scenario has a newer version"
      assert_text "Treat Business SAML as unsupported."
    end
  end

  test "historical consent abstention unknown error and interruption remain honest on desktop and mobile" do
    build_change_impact
    import_impact_document("The current product has different entitlements; compare historical snapshots only.")
    sign_in users(:owner)
    visit new_workspace_corpus_assumption_impact_path(@workspace, @corpus, **impact_selection_params)
    assert_text "Historical comparison"
    fill_in "Model configuration (JSON)", with: impact_configuration.to_json
    click_button "Preview exact model request"
    with_impact_approval do
      check "impact_disclose"
      click_button "Request change analysis"
      assert_selector "[role=alert]", text: /historical comparison is intentional/
      assert_unchecked_field "historical_confirm"
      assert_unchecked_field "impact_disclose"
      check "historical_confirm"
      check "impact_disclose"
      click_button "Request change analysis"
      assert_selector "[role=status]", text: /Queued/
      impact = AssumptionImpact.where(corpus: @corpus).sole
      with_impact_response(response: { "schema" => "invalid" }, calls: calls = []) { 2.times { AssumptionImpactJob.perform_now(impact.id) } }
      click_link "Refresh attempt state"
      assert_selector "h2", text: "Error"
      assert_text "Remote outcome/cost may be unknown"
      assert_no_link "Open current version for separate revision and review"
      assert_equal 1, calls.size
      [ 1280, 390 ].each { |width| capture("error-#{width}", width) }
      response = impact_response.merge("decision" => "abstain", "affected" => [], "reason" => "No supported impact proposal from these synthetic inputs.")
      with_impact_response(response:) do
        abstention = request_impact(historical: true, configuration: impact_configuration.deep_merge("settings" => { "seed" => 41 }))
        AssumptionImpactJob.perform_now(abstention.id)
        visit workspace_corpus_assumption_impact_path(@workspace, @corpus, abstention)
      end
      assert_selector "h2", text: "Abstain"
      assert_text "does not prove that the selected assumptions are unaffected"
      queued = request_impact(historical: true, configuration: impact_configuration.deep_merge("settings" => { "seed" => 42 }))
      visit workspace_corpus_assumption_impact_path(@workspace, @corpus, queued)
      click_button "Interrupt change analysis"
      assert_selector "[role=status]", text: /Interrupted/
      assert_no_button "Interrupt change analysis"
      assert_no_button "Request change analysis"
      [ 1280, 390 ].each { |width| capture("interrupted-#{width}", width) }
    end
  end

  private
    def capture(name, width)
      page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
      page.current_window.resize_to(width, 1000)
      page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width:, height: 1000, deviceScaleFactor: 2, mobile: false)
      assert_equal width, page.evaluate_script("window.innerWidth")
      assert_no_horizontal_overflow
      assert_no_csp_violations
      return unless ENV["CAPTURE_LAB_SCREENSHOTS"] == "1"
      path = Rails.root.join(".amp/in/artifacts/assumption-impact/#{name}.png")
      FileUtils.mkdir_p(path.dirname)
      page.execute_script("window.scrollTo(0, 0)")
      height = page.evaluate_script("document.documentElement.scrollHeight")
      image = page.driver.browser.execute_cdp("Page.captureScreenshot", captureBeyondViewport: true, clip: { x: 0, y: 0, width:, height:, scale: 1 })
      File.binwrite(path, Base64.decode64(image.fetch("data")))
    end
end
