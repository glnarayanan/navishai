require "application_system_test_case"

class CorpusExplorationJourneyTest < ApplicationSystemTestCase
  test "expert searches retained context narrows sources follows exact evidence and recovers from empty and invalid phrases" do
    membership = memberships(:owner_support)
    workspace = membership.workspace
    corpus = workspace.corpora.create!(name: "Technical support search fixture")
    CorpusIntake.call(corpus:, membership:, name: "Support history", kind: "conversations", bytes: File.read(Rails.root.join("test/fixtures/files/support_export.json")))
    CorpusIntake.call(corpus:, membership:, name: "Current SSO policy", kind: "document", bytes: "Enterprise SAML policy requires current metadata.")
    sign_in users(:owner)
    visit workspace_corpus_path(workspace, corpus)
    page.execute_script("window.__corpusJumpFetches = 0; document.addEventListener('turbo:before-fetch-request', () => window.__corpusJumpFetches += 1)")
    click_link "Explore current records"
    assert_includes page.current_url, "#corpus-records"
    assert_equal 0, page.evaluate_script("window.__corpusJumpFetches"), "A same-page jump must not reload and replace the search form."
    fill_in "Search phrase", with: "ENTERPRISE"
    select "Support history", from: "Search source"
    find("input[name=corpus_query]").send_keys(:enter)
    within "#corpus-records" do
      assert_selector "[role=status]", text: "1 matching record"
      find("summary", text: "sso-7 · SAML certificate expiry").click
      assert_text "[email redacted]"
      assert_no_text "admin@example.org"
      find("summary", text: "Retained context").click
      assert_text '"plan": "enterprise"'
    end
    [ 1280, 390 ].each { |width| capture("matches-#{width}", width) }
    click_link "Support history · snapshot 1 · record sso-7"
    assert_selector "h1", text: "Support history"
    assert_text "After rotating the IdP certificate"
    assert_not_includes page.current_url, "record_id="
    assert_includes page.current_url, "#record-"
    click_link corpus.name
    fill_in "Search phrase", with: "no such diagnostic phrase"
    click_button "Search retained records"
    within "#corpus-records" do
      assert_selector "[role=status]", text: "0 matching records"
      assert_text "No records on this page."
    end
    capture("empty-390", 390)
    click_link "Clear search"
    assert_field "Search phrase", with: ""
    assert_selector "select[name=source_id] option:checked", text: "All current sources"
    within "#corpus-records" do
      assert_selector "[role=status]", text: "3 matching records"
    end
    visit workspace_corpus_path(workspace, corpus, corpus_query: "x" * 201)
    assert_selector "#corpus-records [role=alert]", text: "200 characters and no null bytes"
    capture("error-390", 390)
    fill_in "Search phrase", with: "metadata"
    select "Current SSO policy", from: "Search source"
    click_button "Search retained records"
    within "#corpus-records" do
      assert_no_selector "[role=alert]"
      assert_selector "[role=status]", text: "1 matching record"
    end
  end

  test "filtered next and previous links stay local when a query supplies route options" do
    membership = memberships(:owner_support)
    workspace = membership.workspace
    corpus = workspace.corpora.create!(name: "Local pagination fixture")
    snapshot = CorpusIntake.call(corpus:, membership:, name: "Diagnostic export", kind: "conversations",
      bytes: 51.times.map { |index| { id: "diagnostic-#{index}", title: "Certificate evidence #{index}", content: "Collect current certificate diagnostics." } }.to_json)
    sign_in users(:owner)
    visit workspace_corpus_path(workspace, corpus, corpus_query: "certificate", source_id: snapshot.source_id, protocol: "javascript", host: "alert(1)//", anchor: "corpus-records")
    origin = URI(page.current_url).then { |url| [ url.scheme, url.host, url.port ] }
    assert_no_difference [ "CorpusItem.count", "AuditEvent.count", "Scenario.count" ] do
      within "#corpus-records" do
        assert_selector "[role=status]", text: "51 matching records"
        assert_selector "details.source-record", count: 50
        assert_selector "a[href^='/workspaces/']", text: "Next records"
        find("a", text: "Next records").send_keys(:enter)
      end
      within "#corpus-records" do
        assert_selector "details.source-record", count: 1
        assert_text "diagnostic-50 · Certificate evidence 50"
        assert_field "Search phrase", with: "certificate"
        assert_field "Search source", with: snapshot.source_id.to_s
        assert_selector "a[href^='/workspaces/']", text: "Previous records"
        click_link "Previous records"
        assert_selector "details.source-record", count: 50
        assert_selector "[role=status]", text: "51 matching records · page 1"
      end
    end
    assert_equal origin, URI(page.current_url).then { |url| [ url.scheme, url.host, url.port ] }
    assert_no_horizontal_overflow
    assert_no_csp_violations
  end

  test "a fresh corpus navigation cannot replace a phrase typed into its cached preview" do
    membership = memberships(:owner_support)
    workspace = membership.workspace
    corpus = workspace.corpora.create!(name: "Cached navigation fixture")
    CorpusIntake.call(corpus:, membership:, name: "Policy", kind: "document", bytes: "SAML requires metadata.")
    sign_in users(:owner)
    visit workspace_corpus_path(workspace, corpus)
    click_link "Policy", exact: true
    assert_selector "h1", text: "Policy"
    entered, release = Queue.new, Queue.new
    calls = 0
    delay = ->(event) do
      if event.payload[:controller] == "CorporaController" && event.payload[:action] == "show"
        calls += 1
        if calls == 1
          entered << true
          release.pop
        end
      end
    end
    ActiveSupport::Notifications.subscribed(delay, "start_processing.action_controller") do
      click_link corpus.name
      Timeout.timeout(5) { entered.pop }
      if page.has_selector?("html[data-turbo-preview]", wait: 0.5)
        fill_in "Search phrase", with: "no matching diagnostics"
        release << true
        assert_selector "html:not([data-turbo-preview]):not([aria-busy=true])"
      else
        assert_no_selector "input[name=corpus_query]"
        release << true
        fill_in "Search phrase", with: "no matching diagnostics"
      end
      click_button "Search retained records"
      assert_selector "#corpus-records [role=status]", text: "0 matching records"
      assert_field "Search phrase", with: "no matching diagnostics"
    end
  ensure
    release << true if release
  end

  private
    def capture(name, width)
      page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width:, height: 1000, deviceScaleFactor: 2, mobile: false)
      assert_no_horizontal_overflow
      assert_no_csp_violations
      return unless ENV["CAPTURE_LAB_SCREENSHOTS"] == "1"

      path = Rails.root.join(".amp/in/artifacts/corpus-exploration/#{name}.png")
      FileUtils.mkdir_p(path.dirname)
      page.execute_script("window.scrollTo(0, 0)")
      size = page.driver.browser.execute_cdp("Page.getLayoutMetrics").fetch("cssContentSize")
      image = page.driver.browser.execute_cdp("Page.captureScreenshot", captureBeyondViewport: true, clip: { x: 0, y: 0, width:, height: size.fetch("height"), scale: 1 })
      File.binwrite(path, Base64.decode64(image.fetch("data")))
    end
end
