require "application_system_test_case"

class StreamingDiscoveryJourneyTest < ApplicationSystemTestCase
  include ActiveJob::TestHelper

  test "expert deliberately selects streaming after original bounds refuse and sees complete local selection" do
    membership = memberships(:owner_support)
    workspace = membership.workspace
    corpus = workspace.corpora.create!(name: "Synthetic larger local corpus")
    snapshot = CorpusIntake.call(corpus:, membership:, name: "Synthetic history", kind: "conversations",
      bytes: [ { id: "0000", title: "Certificate metadata expiry", content: "Certificate metadata expiry." } ].to_json)
    attributes = { workspace_id: workspace.id, corpus_id: corpus.id, source_snapshot_id: snapshot.id,
      title: "Certificate metadata expiry", content: "Certificate metadata expiry.", context: {}, created_at: Time.current }
    2000.times.each_slice(1000) { |indexes| CorpusItem.insert_all!(indexes.map { |index| attributes.merge(external_id: format("%04d", index + 1)) }) }
    sign_in users(:owner)
    visit workspace_corpus_path(workspace, corpus)
    assert_field "Local method", with: "local"
    assert_no_difference "CorpusAnalysis.count" do
      click_button "Analyse corpus locally"
      assert_selector "[role=alert]", text: "1–2000 conversation/document records"
    end
    select "Streaming local · 100,000 records / 1 GiB", from: "Local method"
    fill_in "Candidate limit", with: 2
    capture("picker")
    find("input[value='Analyse corpus locally']").send_keys(:enter)
    assert_selector "h1", text: "Corpus analysis"
    assert_text CorpusAnalysis::STREAM_METHOD
    assert_text "Waiting for the local processing job"
    assert_text "No data leaves this deployment."
    perform_enqueued_jobs
    click_link "Refresh result"
    assert_text "2 candidates selected from 2001 conversations"
    assert_text "not verified issue-family coverage"
    assert_text "2 million seed comparisons"
    assert_equal 2001, ClusterMember.where(issue_cluster: corpus.corpus_analyses.sole.issue_clusters).count
    capture("complete")
    capture("review", target: "section[aria-labelledby='family-selection']")
    analysis = CorpusAnalysis.request!(corpus:, membership:, scenario_limit: 2, processing_method: "local_stream")
    snapshot.source.update!(expires_at: 1.minute.from_now)
    travel 2.minutes do
      CorpusAnalysisJob.perform_now(analysis.id)
      assert_equal "failed", analysis.reload.state
    end
    visit workspace_corpus_corpus_analysis_path(workspace, corpus, analysis)
    assert_selector "[role=alert]", text: "expired"
    assert_no_selector "input[value='Create selected scenarios']"
    capture("failed")
  end

  test "oversized complete evidence pages keep honest counts and recover through source filters and next pages" do
    membership = memberships(:owner_support)
    workspace = membership.workspace
    corpus = workspace.corpora.create!(name: "Synthetic large evidence fixture")
    snapshot = CorpusIntake.call(corpus:, membership:, name: "Large retained context", kind: "conversations",
      bytes: [ { id: "large-a", title: "Certificate metadata", content: "Collect certificate metadata.", context: { details: "é" * 3.megabytes } } ].to_json)
    attributes = { workspace_id: workspace.id, corpus_id: corpus.id, source_snapshot_id: snapshot.id,
      title: "Certificate metadata", content: "Collect certificate metadata.", context: {}, created_at: Time.current }
    CorpusItem.insert_all!([ attributes.merge(external_id: "large-b", context: { details: "é" * 3.megabytes }) ])
    CorpusItem.insert_all!(50.times.map { |index| attributes.merge(external_id: "small-#{index}", context: index == 49 ? { impact: "critical" } : {}) })
    analysis = CorpusAnalysis.request!(corpus:, membership:, scenario_limit: 1, processing_method: "local_stream")
    CorpusAnalysisJob.perform_now(analysis.id)
    assert_equal "complete", analysis.reload.state
    sign_in users(:owner)
    visit workspace_corpus_path(workspace, corpus, anchor: "corpus-records")
    within "#corpus-records" do
      assert_selector "[role=status]", text: "52 matching records"
      assert_selector "[role=alert]", text: "no page records were loaded"
      assert_no_selector "details.source-record"
    end
    capture("corpus-blocked", target: "#corpus-records")
    within "#corpus-records" do
      find("a", text: "Next records").send_keys(:enter)
      assert_selector "details.source-record", count: 2
      assert_no_selector "[role=alert]"
    end
    visit workspace_corpus_source_path(workspace, corpus, snapshot.source, snapshot: 1, anchor: "source-evidence")
    assert_selector "#source-evidence [role=alert]", text: "does not include historical snapshots"
    assert_no_selector "#source-evidence article"
    capture("source-blocked", target: "#source-evidence")
    click_link "Next records"
    assert_selector "#source-evidence article", count: 2
    assert_no_selector "#source-evidence [role=alert]"
    cluster = analysis.issue_clusters.sole
    visit workspace_corpus_corpus_analysis_path(workspace, corpus, analysis)
    assert_selector "[role=alert]", text: "complete evidence read exceeds 10 MiB"
    assert_no_selector "details.source-record"
    capture("overview-blocked")
    find("#bounded-family-links a").click
    assert_current_path workspace_corpus_corpus_analysis_issue_cluster_path(workspace, corpus, analysis, cluster)
    assert_selector "#family-records [role=status]", text: "52 matching records of 52"
    assert_selector "#family-records [role=alert]", text: "no page records were loaded"
    assert_no_selector "#family-records > details"
    capture("family-blocked", target: "#family-records")
    select "reported critical impact (1 / 52)", from: "Source signal filter"
    click_button "Filter source records"
    assert_selector "#family-records [role=status]", text: "1 matching record of 52"
    assert_selector "#family-records > details", count: 1
    assert_no_selector "#family-records [role=alert]"
    capture("family-recovered", target: "#family-records")
  end

  private
    def capture(name, target: nil)
      [ 1280, 390 ].each do |width|
        page.current_window.resize_to(width, 1600)
        page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width:, height: 1600, deviceScaleFactor: 2, mobile: false)
        Selenium::WebDriver::Wait.new(timeout: Capybara.default_max_wait_time).until { page.evaluate_script("window.innerWidth") == width }
        page.execute_script("arguments[0].scrollIntoView({block: 'start'})", find(target)) if target
        assert_no_horizontal_overflow
        assert_no_csp_violations
        next unless ENV["CAPTURE_LAB_SCREENSHOTS"] == "1"

        path = Rails.root.join(".amp/in/artifacts/streaming-discovery/#{name}-#{width}.png")
        FileUtils.mkdir_p(path.dirname)
        save_screenshot(path)
      end
    ensure
      page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
    end
end
