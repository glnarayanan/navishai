require "application_system_test_case"
require_relative "../test_helpers/trace_failure_discovery_test_helper"

class TraceFailureDiscoveryJourneyTest < ApplicationSystemTestCase
  include TraceFailureDiscoveryTestHelper

  test "expert explicitly discovers unreported failures inspects gaps and opens only an unapproved source backed draft" do
    build_trace_discovery
    sign_in users(:owner)
    visit new_workspace_corpus_trace_failure_discovery_path(@workspace, @corpus)
    assert_text "Default remains no model transmission"
    assert_text "4 complete traces"
    fill_in "Model configuration (JSON)", with: "{incomplete"
    click_button "Request trace failure discovery"
    assert_selector "[role=alert]", text: /valid JSON/
    assert_field "Model configuration (JSON)", with: "{incomplete"
    assert_no_selector "input#trace_discovery_disclose:checked"
    fill_in "Model configuration (JSON)", with: discovery_configuration.to_json
    with_trace_discovery_approval do
      click_button "Request trace failure discovery"
      assert_selector "[role=alert]", text: /Confirm the exact contents/
      assert_equal 0, TraceFailureDiscovery.where(corpus: @corpus).count
      find("input#trace_discovery_disclose").send_keys(:space)
      assert_selector "input#trace_discovery_disclose:checked"
      [ 1280, 390 ].each { |width| capture("preview-#{width}", width) }
      assert_selector "label[for=trace_discovery_disclose]", text: /scenario definitions and compiled cases.*separate trace-discovery purpose.*proposed failure, emerging-family and coverage-gap discovery/
      assert_text "Corpus, target, judge, scenario or matching approval cannot grant this purpose"
      capture("preview-form-390", 390, target: "Request discovery")
      click_button "Request trace failure discovery"
      assert_selector "h1", text: "Trace failure discovery", exact_text: true
      assert_text "All 4 disclosed traces remain unassessed"
      [ 1280, 390 ].each { |width| capture("queued-#{width}", width) }
      discovery = TraceFailureDiscovery.where(corpus: @corpus).sole
      calls = []
      with_trace_discovery_response(calls:) { 2.times { TraceFailureDiscoveryJob.perform_now(discovery.id) } }
      click_link "Refresh result"
      assert_selector "#trace-accounting", text: /4 of 4.*2 proposed failures, 1 no finding, 1 abstention/
      assert_selector "#trace-#{@items.fetch('unreported').id}", text: /uploader reported failure: no/
      assert_equal 1, calls.size
      assert_equal 1, @corpus.scenarios.count
      [ 1280, 390 ].each { |width| capture("result-#{width}", width) }
      find("summary", text: "Destructive retry safety · 1 supporting trace").click
      find("summary", text: "No destructive-retry case in the disclosed set").click
      assert_text "Never replay a destructive delete"
      assert_text "Complete disclosed comparison references: scenario-version-#{@scenario.current_version_id}, eval-case-#{@case.id}"
      [ 1280, 390 ].each { |width| capture("gaps-#{width}", width, target: "Proposed emerging issue families") }
      within "#trace-#{@items.fetch('unreported').id}" do
        select "Accept for scenario work", from: "Expert decision"
        fill_in "Your reason", with: "I inspected the full trace and exact company policy."
        click_button "Save expert decision"
      end
      assert_text "Expert decision appended"
      assert_equal 1, @corpus.scenarios.count
      click_button "Open unapproved scenario draft"
      assert_selector "h1", text: "Unreported destructive retry"
      assert_field "Customer starting situation", with: "A webhook retry deleted the same record twice."
      assert_field "Outcomes — one requirement per line", with: ""
      assert_text "needs review"
      assert_equal 0, HumanLabel.where(corpus: @corpus).count
      assert_equal 0, RegressionCase.where(corpus: @corpus).count
      assert_not @corpus.scenarios.find_by!(corpus_item: @items.fetch("unreported")).current_version.approved?
    end
  end

  test "abstention execution error expired evidence and interrupted attempts never imply failures or grants" do
    build_trace_discovery
    sign_in users(:owner)
    response = trace_discovery_response.merge("decision" => "abstain", "emerging_families" => [], "coverage_gaps" => [])
    response["trace_accounts"] = response.fetch("trace_accounts").map { |account| account.merge("decision" => "abstain", "evidence" => []) }
    with_trace_discovery_response(response:) do
      discovery = request_trace_discovery
      TraceFailureDiscoveryJob.perform_now(discovery.id)
      visit workspace_corpus_trace_failure_discovery_path(@workspace, @corpus, discovery)
      assert_selector "h2", text: "Abstain", exact_text: true
      assert_text "4 of 4 disclosed traces accounted for: 0 proposed failures"
      assert_no_button "Save expert decision"
      capture("abstain-390", 390)
    end
    with_trace_discovery_response(response: { "schema" => "invalid" }) do
      discovery = request_trace_discovery
      TraceFailureDiscoveryJob.perform_now(discovery.id)
      visit workspace_corpus_trace_failure_discovery_path(@workspace, @corpus, discovery)
      assert_selector "h2", text: "Error", exact_text: true
      assert_text "All 4 disclosed traces are unassessed"
      assert_text "Remote outcome/cost may be unknown"
      assert_no_button "Save expert decision"
      assert_link "Review a new preview", href: new_workspace_corpus_trace_failure_discovery_path(@workspace, @corpus)
      [ 1280, 390 ].each { |width| capture("error-#{width}", width) }
      @document.source_snapshot.source.update!(expires_at: 1.second.ago)
      click_link "Refresh result"
      assert_selector "[role=alert]", text: /contents, findings and decisions are hidden/
      assert_no_selector "pre"
      capture("expired-390", 390)
      @document.source_snapshot.source.update!(expires_at: 30.days.from_now)
    end
    with_trace_discovery_approval do
      queued = request_trace_discovery
      visit workspace_corpus_trace_failure_discovery_path(@workspace, @corpus, queued)
      click_button "Interrupt discovery attempt"
      assert_text "All 4 disclosed traces remain unassessed by this attempt"
      assert_no_button "Interrupt discovery attempt"
      capture("interrupted-390", 390)
    end
    assert_equal 1, @corpus.scenarios.count
  end

  private
    def capture(name, width, target: nil)
      page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width:, height: 1200, deviceScaleFactor: 2, mobile: false)
      assert_no_horizontal_overflow
      assert_no_csp_violations
      return unless ENV["CAPTURE_LAB_SCREENSHOTS"] == "1"
      path = Rails.root.join(".amp/in/artifacts/trace-discovery/#{name}.png")
      FileUtils.mkdir_p(path.dirname)
      y = target ? find("h2", text: target, exact_text: true).evaluate_script("this.getBoundingClientRect().top + window.scrollY") - 15 : 0
      height = [ page.evaluate_script("document.documentElement.scrollHeight") - y, target ? 2600 : 1600 ].min
      image = page.driver.browser.execute_cdp("Page.captureScreenshot", captureBeyondViewport: true, clip: { x: 0, y:, width:, height:, scale: 1 })
      File.binwrite(path, Base64.decode64(image.fetch("data")))
    end
end
