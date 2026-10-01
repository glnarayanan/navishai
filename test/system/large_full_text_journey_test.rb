require "application_system_test_case"

class LargeFullTextJourneyTest < ApplicationSystemTestCase
  include ActiveJob::TestHelper
  include ActiveSupport::Testing::ConstantStubbing

  test "expert deliberately selects v4 above old count and byte bounds and inspects complete late diagnostic families" do
    membership = memberships(:owner_support)
    workspace = membership.workspace
    corpus = workspace.corpora.create!(name: "Synthetic large late-diagnostic history")
    snapshot = CorpusIntake.call(corpus:, membership:, name: "Long history", kind: "conversations",
      bytes: [ { id: "0000", title: "Imported record", content: "Shared preamble. " + " " * 5000 + "Nacre certificate metadata expiry. " * 20 } ].to_json)
    ApplicationRecord.connection.execute(<<~SQL)
      INSERT INTO corpus_items (workspace_id, corpus_id, source_snapshot_id, external_id, title, content, context, created_at)
      SELECT #{workspace.id}, #{corpus.id}, #{snapshot.id}, lpad(i::text, 4, '0'), 'Imported record',
        'Shared preamble. ' || repeat(' ', 5000) ||
          CASE WHEN i < 1000 THEN repeat('Nacre certificate metadata expiry. ', 20)
            ELSE repeat('Quasar pagination checkpoint discarded. ', 20) END,
        CASE WHEN i = 2000 THEN '{"impact":"critical"}'::jsonb ELSE '{}'::jsonb END, NOW()
      FROM generate_series(1, 2000) AS i
    SQL
    assert_equal 2001, corpus.current_items.count
    assert_operator corpus.current_items.sum(CorpusAnalysis::RECORD_BYTES_SQL), :>, 10.megabytes
    sign_in users(:owner)
    visit workspace_corpus_path(workspace, corpus)
    assert_field "Local method", with: "local"
    select "Full-text local · 2000 records / 10 MiB", from: "Local method"
    assert_no_difference "CorpusAnalysis.count" do
      click_button "Analyse corpus locally"
      assert_selector "[role=alert]", text: "1–2000 conversation/document records"
    end
    assert_field "Local method", with: "local_full_text"
    select "Large full-text · 100,000 / 1 GiB", from: "Local method"
    fill_in "Candidate limit", with: 3
    assert_text "Original and streaming use only the first 4000 characters"
    assert_text "Complete evidence reads and mining stay within 10 MiB"
    capture("selected", target: "section:has(select[name=processing_method])")
    find("input[value='Analyse corpus locally']").send_keys(:enter)
    assert_selector "h1", text: "Corpus analysis"
    assert_text "tfidf-large-full-text-seed-centroid-selection-v4"
    assert_text "the complete text of each conversation"
    assert_text "Waiting for the local processing job. No data leaves this deployment."
    capture("queued")
    perform_enqueued_jobs
    click_link "Refresh result"
    assert_text "3 candidates selected from 2001 conversations"
    assert_text "2 of 2 term clusters represented"
    assert_text "not verified issue-family coverage"
    assert_text "Large full-text local limits: 100,000 complete records / 1 GiB"
    assert_text "Taxonomy: unreviewed proposals"
    assert_selector "h2", text: "certificate / expiry / metadata"
    assert_selector "h2", text: "checkpoint / discarded / pagination"
    assert_button "Create selected scenarios"
    analysis = corpus.corpus_analyses.sole
    assert_equal 2001, ClusterMember.where(issue_cluster: analysis.issue_clusters).count
    assert_equal %w[0000 1000 2000], ClusterMember.selected.where(issue_cluster: analysis.issue_clusters).joins(:corpus_item).order("corpus_items.external_id").pluck("corpus_items.external_id")
    assert_equal [ snapshot.id ], analysis.corpus_items.pluck(:source_snapshot_id).uniq
    assert_empty analysis.taxonomy_versions
    capture("complete")

    visit workspace_corpus_path(workspace, corpus)
    select "Large full-text · 100,000 / 1 GiB", from: "Local method"
    click_button "Analyse corpus locally"
    assert_selector "h1", text: "Corpus analysis"
    stub_const(CorpusDiscovery, :MAX_TERM_ENTRIES, 1) do
      assert_no_difference([ "IssueCluster.count", "ClusterMember.count", "Scenario.count" ]) { perform_enqueued_jobs }
    end
    click_link "Refresh result"
    assert_selector "[role=alert]", text: /Large full-text local discovery exceeded.*budget/
    assert_no_button "Create selected scenarios"
    assert_no_selector "details.source-record"
    assert_no_selector "main form[method=post]"
    assert_empty corpus.corpus_analyses.order(:id).last.summary
    capture("error")
    assert_no_difference([ "IssueCluster.count", "ClusterMember.count", "AuditEvent.count" ]) { click_link "Refresh result" }
    click_link "Synthetic large late-diagnostic history"
    assert_selector "h1", text: corpus.name
    assert_field "Local method", with: "local"
  end

  test "blocked v4 overview keeps bounded fixed-family recovery and no partial or write controls" do
    membership = memberships(:owner_support)
    workspace = membership.workspace
    corpus = workspace.corpora.create!(name: "Synthetic large complete evidence")
    2.times do |index|
      CorpusIntake.call(corpus:, membership:, name: "Large context #{index}", kind: "conversations",
        bytes: [ { id: "large-#{index}", title: "Quasar replay", content: "Quasar replay.", context: { details: "é" * 3.megabytes } } ].to_json)
    end
    snapshot = CorpusIntake.call(corpus:, membership:, name: "Small fixed record", kind: "conversations",
      bytes: [ { id: "small", title: "Certificate metadata", content: "Collect certificate metadata." } ].to_json)
    analysis = CorpusAnalysis.request!(corpus:, membership:, scenario_limit: 2, processing_method: "local_large_full_text")
    CorpusAnalysisJob.perform_now(analysis.id)
    assert_equal "complete", analysis.reload.state
    sign_in users(:owner)
    visit workspace_corpus_corpus_analysis_path(workspace, corpus, analysis)
    assert_selector "[role=alert]", text: "complete evidence read exceeds 10 MiB"
    assert_text "This fixed analysis has not changed"
    assert_text "Only this evidence preview is blocked"
    assert_selector "#bounded-family-links a", count: 2
    assert_no_selector "details.source-record"
    assert_no_selector "main form[method=post]"
    capture("blocked-evidence")
    cluster = analysis.issue_clusters.joins(:cluster_members).find_by!(cluster_members: { corpus_item_id: snapshot.corpus_items.sole.id })
    find("#bounded-family-links a[href='#{workspace_corpus_corpus_analysis_issue_cluster_path(workspace, corpus, analysis, cluster)}']").send_keys(:enter)
    assert_selector "h1", text: "Family source evidence"
    assert_text "certificate / metadata / collect"
    assert_text "1 matching record of 1"
    assert_no_selector "[role=alert]"
    assert_selector "#family-records > details", count: 1
    assert_equal 2, analysis.issue_clusters.count
    assert_empty analysis.taxonomy_versions
  end

  private
    def capture(name, target: nil)
      [ 1280, 390 ].each do |width|
        page.current_window.resize_to(width, 1600)
        page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width:, height: 1600, deviceScaleFactor: 2, mobile: false)
        Selenium::WebDriver::Wait.new(timeout: Capybara.default_max_wait_time).until { page.evaluate_script("window.innerWidth") == width }
        assert_equal width, page.evaluate_script("window.innerWidth")
        assert_equal 2, page.evaluate_script("window.devicePixelRatio")
        page.execute_script("arguments[0].scrollIntoView({block: 'start'})", find(target)) if target
        assert_no_horizontal_overflow
        assert_no_csp_violations
        next unless ENV["CAPTURE_LAB_SCREENSHOTS"] == "1"

        path = Rails.root.join(".amp/in/artifacts/large-full-text/#{name}-#{width}.png")
        FileUtils.mkdir_p(path.dirname)
        save_screenshot(path)
      end
    ensure
      page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
    end
end
