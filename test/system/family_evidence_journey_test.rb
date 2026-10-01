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
    entered, release = Queue.new, Queue.new
    assert_no_difference [ "AuditEvent.count", "CorpusAnalysis.count", "ClusterMember.count", "TaxonomyVersion.count", "Scenario.count" ] do
      assert_no_enqueued_jobs do
        visit workspace_corpus_corpus_analysis_path(@workspace, @corpus, @analysis)
        assert_no_button "Save expert label"
        click_link "Explore all family records and source counts"
        assert_selector "h1", text: "Family source evidence"
        assert_text "not verified outcomes, risk or expert labels"
        assert_no_button "Create scenario draft"
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
        old_records = find("#family-records").native
        delay = ->(event) do
          if event.payload[:controller] == "IssueClustersController" && event.payload[:action] == "show"
            entered << true
            release.pop
          end
        end
        ActiveSupport::Notifications.subscribed(delay, "start_processing.action_controller") do
          click_link "Refresh evidence"
          Timeout.timeout(5) { entered.pop }
          assert_selector "html[aria-busy=true]"
          # Old counts and selected options also pass while refresh is pending.
          assert_selector "#family-records > details", count: 5
          assert_selector "select option:checked", text: "diagnostic evidence mention (55 / 55)"
          release << true
          Selenium::WebDriver::Wait.new(timeout: Capybara.default_max_wait_time).until do
            begin
              old_records.enabled?
              false
            rescue Selenium::WebDriver::Error::StaleElementReferenceError
              true
            end
          end
        end
        assert_selector "html:not([aria-busy=true]):not([data-turbo-preview])"
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
  ensure
    release << true if release
  end

  test "expert repairs nomination then opens one unapproved historical draft without changing selection" do
    build_family_evidence_fixture
    refresh_family_export
    member = @cluster.cluster_members.find_by!(corpus_item: @items[50])
    fixed_analysis = @analysis.attributes
    path = workspace_corpus_corpus_analysis_issue_cluster_path(@workspace, @corpus, @analysis, @cluster, signal: "diagnostic evidence mention", page: 2)
    sign_in users(:owner)
    assert_no_enqueued_jobs do
      visit path
      find("#member-#{member.id} summary").send_keys(:enter)
      within "#member-#{member.id}" do
        assert_text "does not change the method's selection"
        fill_in "Why this record needs a scenario", with: "   "
      end
      [ 1280, 390 ].each { |width| capture(width, name: "nomination", selector: "#member-#{member.id} form") }
      assert_no_difference [ "Scenario.count", "ScenarioVersion.count", "ScenarioEvidence.count", "AuditEvent.count", "HumanLabel.count" ] do
        within("#member-#{member.id}") { find("input[value='Create scenario draft']").send_keys(:enter) }
        assert_selector "#nomination-error-#{member.id}[role=alert]", text: "1–2000 characters"
        assert_selector "#member-#{member.id}[open] textarea[aria-invalid=true]"
        assert_equal "   ", find("#reason-#{member.id}").value
        assert_selector "#family-records [role=status]", text: "55 matching records of 55 fixed family records · page 2"
      end
      [ 1280, 390 ].each { |width| capture(width, name: "nomination-error", selector: "#member-#{member.id} form") }
      click_link "Previous records"
      assert_selector "#family-records > details", count: 50
      assert_includes page.current_url, "signal=diagnostic"
      click_link "Next records"
      assert_selector "#family-records > details", count: 5
      assert_selector "html:not([aria-busy=true]):not([data-turbo-preview])"
      find("#member-#{member.id} summary").send_keys(:enter)
      assert_selector "#member-#{member.id}[open] textarea"
      reason = "Fixture expert: verify this reported failure against retained company evidence."
      assert_difference([ "Scenario.count", "ScenarioVersion.count", "ScenarioEvidence.count", "AuditEvent.count" ], 1) do
        within "#member-#{member.id}" do
          fill_in "Why this record needs a scenario", with: reason
          find("input[value='Create scenario draft']").send_keys(:enter)
        end
        assert_selector "h1", text: "Diagnostic 51"
        assert_text "needs review"
        assert_text "Expert nominated this fixed record for review: #{reason}"
      end
      scenario = @corpus.scenarios.sole
      assert_not scenario.current_version.approved?
      assert_empty scenario.current_version.requirements["outcomes"]
      assert_equal @items[50], scenario.current_version.scenario_evidence.sole.corpus_item
      assert_equal fixed_analysis, @analysis.reload.attributes
      assert_nil member.reload.selection_reason
      assert_equal 0, HumanLabel.where(corpus: @corpus).count
      visit path
      find("#member-#{member.id} summary").send_keys(:enter)
      within "#member-#{member.id}" do
        assert_no_button "Create scenario draft"
        assert_link "Open existing scenario", href: workspace_corpus_scenario_path(@workspace, @corpus, scenario)
      end
      [ 1280, 390 ].each { |width| capture(width, name: "existing-scenario", selector: "#member-#{member.id} p") }
    end
  end

  private
    def capture(width, name: "records", selector: nil)
      page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width:, height: 1000, deviceScaleFactor: 2, mobile: false)
      assert_no_horizontal_overflow
      assert_no_csp_violations
      return unless ENV["CAPTURE_LAB_SCREENSHOTS"] == "1"

      path = Rails.root.join(".amp/in/artifacts/family-evidence/#{name}-#{width}.png")
      FileUtils.mkdir_p(path.dirname)
      page.execute_script("window.scrollTo(0, 0)")
      size = page.driver.browser.execute_cdp("Page.getLayoutMetrics").fetch("cssContentSize")
      clip = { x: 0, y: 0, width:, height: size.fetch("height"), scale: 1 }
      if selector
        bounds = page.evaluate_script("(() => { const node = document.querySelector(#{selector.to_json}); const record = node.closest('.source-record'); return { top: record.getBoundingClientRect().top, bottom: node.getBoundingClientRect().bottom }; })()")
        clip[:y] = bounds.fetch("top").floor
        clip[:height] = (bounds.fetch("bottom") - clip[:y] + 80).ceil
      end
      image = page.driver.browser.execute_cdp("Page.captureScreenshot", captureBeyondViewport: true, clip:)
      File.binwrite(path, Base64.decode64(image.fetch("data")))
    end
end
