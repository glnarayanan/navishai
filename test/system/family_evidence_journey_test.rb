require "application_system_test_case"
require_relative "../test_helpers/family_evidence_fixture"

class FamilyEvidenceJourneyTest < ApplicationSystemTestCase
  include ActiveJob::TestHelper
  include FamilyEvidenceFixture

  test "viewer filters with Enter refreshes paginates and follows frozen record 51 without writes" do
    build_family_evidence_fixture
    refresh_family_export
    Membership.create!(workspace: @workspace, user: users(:teammate), role: :viewer)
    sign_in users(:teammate)
    assert_no_difference [ "AuditEvent.count", "CorpusAnalysis.count", "ClusterMember.count", "TaxonomyVersion.count", "Scenario.count" ] do
      assert_no_enqueued_jobs do
        visit workspace_corpus_corpus_analysis_path(@workspace, @corpus, @analysis)
        assert_no_button "Save expert label"
        click_link "Explore all family records and source counts"
        assert_selector "h1", text: "Family source evidence"
        assert_text "not verified outcomes, risk or expert labels"
        select "diagnostic evidence mention (55 / 55)", from: "Source signal filter"
        find("select[name=signal]").send_keys(:enter)
        # Enter on a native select commits its option; submitting the GET with the
        # focused button exercises keyboard-only submission across Chrome versions.
        find("input[value='Filter source records']").send_keys(:enter)
        assert_current_path(/signal=diagnostic/, url: true)
        assert_selector "#family-records > details", count: 50
        click_link "Next records"
        assert_selector "#family-records > details", count: 5
        assert_selector "#family-records [role=status]", text: "55 matching records of 55"
        click_link "Refresh evidence"
        assert_includes page.current_url, "page=2"
        assert_selector "select option:checked", text: "diagnostic evidence mention (55 / 55)"
        find("#family-records summary", text: "family-51 · Diagnostic 51", exact_text: true).click
        assert_text '"plan": "enterprise"'
        assert_text "<script>untrusted()</script>"
        [ 1280, 390 ].each { |width| capture(width) }
        click_link "Family history · snapshot 1 · record family-51"
        assert_selector "article#record-#{@items[50].id}"
        assert_includes page.current_url, "snapshot=1"
        assert_includes page.current_url, "page=2"
        assert_includes page.current_url, "#record-#{@items[50].id}"
        assert_no_button "Prepare snapshot download"
        visit workspace_corpus_corpus_analysis_issue_cluster_path(@workspace, @corpus, @analysis, @cluster, signal: "risk mention", page: 2)
        assert_selector "#family-records [role=status]", text: "2 matching records of 55"
        assert_no_selector "#family-records > details"
        [ 1280, 390 ].each { |width| capture(width, name: "empty") }
        click_link "return to the first page"
        assert_selector "#family-records > details", count: 2
        visit workspace_corpus_corpus_analysis_issue_cluster_path(@workspace, @corpus, @analysis, @cluster, signal: "unknown signal")
        assert_selector "#signal-error[role=alert]", text: "Unknown source signal filter"
        assert_selector "select[aria-invalid=true][aria-describedby=signal-error]"
        assert_no_selector "#family-records > details"
        [ 1280, 390 ].each { |width| capture(width, name: "invalid") }
        click_link "Clear filter"
        assert_selector "#family-records > details", count: 50
      end
    end
  end

  private
    def capture(width, name: "records")
      page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width:, height: 1000, deviceScaleFactor: 2, mobile: false)
      assert_no_horizontal_overflow
      assert_no_csp_violations
      return unless ENV["CAPTURE_LAB_SCREENSHOTS"] == "1"

      path = Rails.root.join(".amp/in/artifacts/family-evidence/#{name}-#{width}.png")
      FileUtils.mkdir_p(path.dirname)
      page.execute_script("window.scrollTo(0, 0)")
      size = page.driver.browser.execute_cdp("Page.getLayoutMetrics").fetch("cssContentSize")
      image = page.driver.browser.execute_cdp("Page.captureScreenshot", captureBeyondViewport: true, clip: { x: 0, y: 0, width:, height: size.fetch("height"), scale: 1 })
      File.binwrite(path, Base64.decode64(image.fetch("data")))
    end
end
