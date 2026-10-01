require "test_helper"
require_relative "../test_helpers/family_evidence_fixture"

class IssueClustersTest < ActionDispatch::IntegrationTest
  include FamilyEvidenceFixture
  setup do
    build_family_evidence_fixture
    sign_in_as users(:owner)
  end

  test "overview links complete explorer and filtered pages retain full denominators and exact historical provenance" do
    get workspace_corpus_corpus_analysis_path(@workspace, @corpus, @analysis)
    assert_response :success
    assert_select "a[href='#{family_path}']", text: "Explore all family records and source counts"
    refresh_family_export
    get family_path, params: { signal: "diagnostic evidence mention" }
    assert_response :success
    assert_select "#family-records > details", count: 50
    assert_select "#source-counts dd", text: "55 / 55 records"
    assert_select "nav a", text: "Next records" do |links|
      assert_includes links.sole["href"], "signal=diagnostic"
    end
    get family_path, params: { signal: "diagnostic evidence mention", page: 2 }
    assert_response :success
    assert_select "#family-records > details", count: 5
    assert_select "select option[selected]", text: "diagnostic evidence mention (55 / 55)"
    assert_select "script", text: /untrusted\(\)/, count: 0
    assert_select "pre", text: /<script>untrusted\(\)<\/script>/
    assert_select "pre", text: /"plan": "enterprise"/
    provenance = workspace_corpus_source_path(@workspace, @corpus, @snapshot.source, snapshot: 1, page: 2, anchor: "record-#{@items[50].id}")
    assert_select "a[href='#{provenance}']"
    get provenance
    assert_response :success
    assert_select "article#record-#{@items[50].id}"
  end

  test "empty and invalid filters recover without silently widening results" do
    get family_path, params: { signal: "risk mention", page: 2 }
    assert_response :success
    assert_select "#family-records > details", count: 0
    assert_select "#family-records [role=status]", text: /2 matching records of 55/
    assert_select "a", text: "return to the first page"
    get family_path, params: { signal: "invented risk" }
    assert_response :unprocessable_content
    assert_select "#family-records [role=alert]", text: /Unknown source signal/
    assert_select "#family-records > details", count: 0
    assert_select "#source-counts dd", text: "55 / 55 records"
    get family_path
    assert_response :success
    assert_select "#family-records > details", count: 50
  end

  test "a filtered group with no matches retains zero and a clear recovery" do
    cluster = @analysis.issue_clusters.create!(workspace: @workspace, corpus: @corpus, proposed_label: "Diagnostic-only family", signals: { "count" => 1 })
    cluster.cluster_members.create!(workspace: @workspace, corpus: @corpus, corpus_item: @items[1], signals: [ "critical importance proposal" ])
    get workspace_corpus_corpus_analysis_issue_cluster_path(@workspace, @corpus, @analysis, cluster), params: { signal: "risk mention" }
    assert_response :success
    assert_select "#family-records > details", count: 0
    assert_select "#family-records [role=status]", text: /0 matching records of 1/
    assert_select "a", text: "Clear filter"
  end

  test "model family page derives the same source counts rather than proposed critical importance" do
    analysis, cluster = build_fixed_family(ModelCorpusDiscovery::VERSION)
    get family_path
    local_counts = css_select("#source-counts").sole.text
    get workspace_corpus_corpus_analysis_issue_cluster_path(@workspace, @corpus, analysis, cluster)
    assert_response :success
    assert_equal local_counts, css_select("#source-counts").sole.text
    assert_select "#family-records [role=status]", text: /55 matching records of 55/
  end

  test "query routing options cannot redirect refresh or pagination away from the fixed family" do
    get family_path, params: { signal: "diagnostic evidence mention", page: 2, controller: "sessions", action: "new", host: "foreign.invalid", protocol: "javascript", script_name: "//foreign.invalid" }
    assert_response :success
    [ "Refresh evidence", "Previous records" ].each do |label|
      assert_select "a", text: label do |links|
        uri = URI.parse(links.sole["href"])
        assert_nil uri.scheme
        assert_nil uri.host
        assert_equal family_path, uri.path
        assert_includes uri.query, "signal=diagnostic"
      end
    end
  end

  test "foreign workspace corpus analysis cluster and expired analysis sources are refused" do
    foreign = @workspace.corpora.create!(name: "Foreign corpus")
    get workspace_corpus_corpus_analysis_issue_cluster_path(workspaces(:beta_support), @corpus, @analysis, @cluster)
    assert_response :not_found
    get workspace_corpus_corpus_analysis_issue_cluster_path(@workspace, foreign, @analysis, @cluster)
    assert_response :not_found
    other_analysis, other_cluster = build_fixed_family(CorpusAnalysis::METHOD)
    get workspace_corpus_corpus_analysis_issue_cluster_path(@workspace, @corpus, other_analysis, @cluster)
    assert_response :not_found
    get workspace_corpus_corpus_analysis_issue_cluster_path(@workspace, @corpus, @analysis, other_cluster)
    assert_response :not_found
    @snapshot.source.update!(expires_at: 1.minute.ago)
    get family_path
    assert_response :not_found
  end

  test "viewer inspection refresh and filtering write no domain records audits or jobs" do
    Membership.create!(workspace: @workspace, user: users(:teammate), role: :viewer)
    sign_in_as users(:teammate)
    assert_no_difference [ "AuditEvent.count", "CorpusItem.count", "ClusterMember.count", "IssueCluster.count", "TaxonomyVersion.count", "Scenario.count", "CorpusAnalysis.count" ] do
      assert_no_enqueued_jobs do
        2.times do
          get family_path, params: { signal: "context.failed: true" }
          assert_response :success
          assert_select "#family-records > details", count: 2
          assert_select "form[method=get]", count: 1
          assert_select "main form[method=post]", count: 0
          assert_select "a", text: "Refresh evidence" do |links|
            assert_includes links.sole["href"], "signal=context.failed"
          end
        end
      end
    end
  end

  private
    def family_path
      workspace_corpus_corpus_analysis_issue_cluster_path(@workspace, @corpus, @analysis, @cluster)
    end
end
