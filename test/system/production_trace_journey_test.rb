require "application_system_test_case"

class ProductionTraceJourneyTest < ApplicationSystemTestCase
  test "expert imports a trace inspects reports and corrects an unapproved scenario" do
    corpus = workspaces(:acme_support).corpora.create!(name: "Production trace fixture lab")
    sign_in users(:owner)
    visit workspace_corpus_path(corpus.workspace, corpus)
    fill_in "Source name", with: "SSO production failure fixture"
    select "Production traces", from: "Source type"
    attach_file "Company data file", Rails.root.join("test/fixtures/files/production_traces.json")
    click_button "Import source"
    assert_selector "h1", text: "SSO production failure fixture"
    assert_text "Reported failures and corrections are not expert labels"
    assert_text "sso-agent-2026-09-28"
    assert_text "[email redacted]"
    assert_no_text "admin@example.org"
    [ 1280, 390 ].each { |width| capture("source-#{width}", width) }
    click_button "Propose scenario from trace"
    assert_selector "h1", text: "SSO certificate rotation"
    assert_text "needs review"
    click_button "Save expert decision"
    assert_selector "[role=alert]", text: "Set a source-backed expected outcome"
    capture("approval-blocked-390", 390)
    fill_in "Issue family", with: "Company SAML diagnostics"
    fill_in "Outcomes — one requirement per line", with: "Request the certificate expiry date before changing configuration."
    click_button "Save new version"
    assert_text "Version 2"
    click_button "Save expert decision"
    assert_text "Expert decision saved for this version"
    assert_link "Compile eval"
    scenario = corpus.scenarios.sole
    assert_equal "Company SAML diagnostics", scenario.current_version.taxonomy_label
    assert scenario.current_version.approved?
    assert_equal "SSO stopped after a customer changed the certificate.", scenario.current_version.situation
    capture("reviewed-390", 390)
  end

  private
    def capture(name, width)
      page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width:, height: 1000, deviceScaleFactor: 2, mobile: false)
      assert_no_horizontal_overflow
      assert_no_csp_violations
      return unless ENV["CAPTURE_LAB_SCREENSHOTS"] == "1"
      path = Rails.root.join(".amp/in/artifacts/production-traces/#{name}.png")
      FileUtils.mkdir_p(path.dirname)
      page.execute_script("window.scrollTo(0, 0)")
      size = page.driver.browser.execute_cdp("Page.getLayoutMetrics").fetch("cssContentSize")
      image = page.driver.browser.execute_cdp("Page.captureScreenshot", captureBeyondViewport: true, clip: { x: 0, y: 0, width:, height: size.fetch("height"), scale: 1 })
      File.binwrite(path, Base64.decode64(image.fetch("data")))
    end
end
