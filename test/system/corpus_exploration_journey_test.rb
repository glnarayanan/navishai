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
    click_link "Explore current records"
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
