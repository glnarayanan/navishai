require "test_helper"
require_relative "../test_helpers/family_evidence_fixture"

class IssueClustersTest < ActionDispatch::IntegrationTest
  include FamilyEvidenceFixture
  setup do
    build_family_evidence_fixture
    sign_in_as users(:owner)
  end

  test "local overview and family pages load only their displayed fixed records" do
    refresh_family_export
    assert_source_rows_loaded(10) do
      get workspace_corpus_corpus_analysis_path(@workspace, @corpus, @analysis)
      assert_response :success
      assert_select "details.source-record", count: 10
      assert_select "p", text: /Showing 10 examples/
      assert_select "summary", text: "Diagnostic 1"
      assert_select "summary", text: "Diagnostic 11", count: 0
    end
    assert_source_rows_loaded(5) do
      get family_path, params: { signal: "diagnostic evidence mention", page: 2 }
      assert_response :success
      assert_select "#family-records > details", count: 5
      assert_select "#family-records [role=status]", text: /55 matching records of 55/
      assert_select "pre", text: /data loss/
    end
    [ { signal: "unknown signal" }, { signal: "risk mention", page: 2 } ].each do |parameters|
      assert_source_rows_loaded(0) { get family_path, params: parameters }
      assert_select "#family-records > details", count: 0
    end
  end

  test "overview selects late nominated examples before earlier unselected records" do
    cluster = @analysis.issue_clusters.create!(workspace: @workspace, corpus: @corpus, proposed_label: "Late selected example", signals: { count: 55 })
    @items.each_with_index do |item, index|
      cluster.cluster_members.create!(workspace: @workspace, corpus: @corpus, corpus_item: item,
        selection_reason: index == 52 ? "Late selected fixture; expert review required." : nil)
    end
    get workspace_corpus_corpus_analysis_path(@workspace, @corpus, @analysis)
    assert_response :success
    assert_select "section[aria-labelledby='cluster-#{cluster.id}']" do |sections|
      assert_select "details.source-record", count: 10
      assert_equal "Diagnostic 53 — selected candidate", sections.sole.at_css("details.source-record summary").text
      assert_select "summary", text: "Diagnostic 10", count: 0
    end
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
        post nominate_workspace_corpus_corpus_analysis_issue_cluster_path(@workspace, @corpus, @analysis, @cluster), params: { member_id: @cluster.cluster_members.first.id, selection_reason: "Viewer cannot nominate" }
        assert_response :forbidden
      end
    end
  end

  test "expert nominates a fixed unselected record with attribution and repeated posts cannot revise it" do
    refresh_family_export
    member = @cluster.cluster_members.find_by!(corpus_item: @items[50])
    definition = @analysis.attributes
    path = nominate_workspace_corpus_corpus_analysis_issue_cluster_path(@workspace, @corpus, @analysis, @cluster)
    assert_difference([ "Scenario.count", "ScenarioVersion.count", "ScenarioEvidence.count", "AuditEvent.count" ], 1) do
      assert_no_enqueued_jobs do
        post path, params: { member_id: member.id, selection_reason: "Expert fixture: investigate this retained failure.", page: 2 }
        assert_response :see_other
      end
    end
    scenario = @corpus.scenarios.sole
    assert_redirected_to workspace_corpus_scenario_path(@workspace, @corpus, scenario)
    version = scenario.current_version
    assert_equal @items[50], version.scenario_evidence.sole.corpus_item
    assert_not version.approved?
    assert_equal @membership.user, version.created_by
    assert_equal definition, @analysis.reload.attributes
    assert_nil member.reload.selection_reason
    saved = version.attributes
    assert_no_difference [ "Scenario.count", "ScenarioVersion.count", "ScenarioEvidence.count", "AuditEvent.count" ] do
      post path, params: { member_id: member.id, selection_reason: "A changed reason must not change the existing draft." }
      assert_response :see_other
    end
    assert_equal saved, version.reload.attributes
    get family_path, params: { page: 2 }
    assert_select "details#member-#{member.id} a[href='#{workspace_corpus_scenario_path(@workspace, @corpus, scenario)}']", text: "Open existing scenario"
    assert_select "details#member-#{member.id} textarea[name=selection_reason]", count: 0
  end

  test "invalid nomination retains exact record page and raw reason with an accessible repair and queues nothing" do
    member = @cluster.cluster_members.find_by!(corpus_item: @items[50])
    reason = "é" * 2001
    assert_no_difference [ "Scenario.count", "ScenarioVersion.count", "ScenarioEvidence.count", "AuditEvent.count" ] do
      assert_no_enqueued_jobs do
        post nominate_workspace_corpus_corpus_analysis_issue_cluster_path(@workspace, @corpus, @analysis, @cluster), params: { member_id: member.id, selection_reason: reason, signal: "diagnostic evidence mention", page: 2 }
        assert_response :unprocessable_content
        assert_select "details#member-#{member.id}[open]"
        assert_select "textarea#reason-#{member.id}[aria-invalid=true][aria-describedby='nomination-error-#{member.id}']", text: reason
        assert_select "#nomination-error-#{member.id}[role=alert]", text: /1–2000 characters.*no null bytes/
        assert_select "#family-records [role=status]", text: /55 matching records of 55.*page 2/
      end
    end
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    assert_equal "[FILTERED]", filter.filter("selection_reason" => "Private expert reason")["selection_reason"]
  end

  test "foreign-member foreign-family foreign-workspace and expired nominations create no records" do
    member = @cluster.cluster_members.first
    other_analysis, other_cluster = build_fixed_family(CorpusAnalysis::METHOD)
    path = nominate_workspace_corpus_corpus_analysis_issue_cluster_path(@workspace, @corpus, @analysis, @cluster)
    assert_no_difference [ "Scenario.count", "ScenarioVersion.count", "ScenarioEvidence.count", "AuditEvent.count" ] do
      assert_no_enqueued_jobs do
        post path, params: { member_id: other_cluster.cluster_members.first.id, selection_reason: "Wrong analysis" }
        assert_response :not_found
        post nominate_workspace_corpus_corpus_analysis_issue_cluster_path(@workspace, @corpus, other_analysis, @cluster), params: { member_id: member.id, selection_reason: "Wrong family" }
        assert_response :not_found
        post nominate_workspace_corpus_corpus_analysis_issue_cluster_path(workspaces(:beta_support), @corpus, @analysis, @cluster), params: { member_id: member.id, selection_reason: "Foreign workspace" }
        assert_response :not_found
        @snapshot.source.update!(expires_at: 1.minute.ago)
        post path, params: { member_id: member.id, selection_reason: "Expired evidence" }
        assert_response :not_found
      end
    end
  end

  private
    def family_path
      workspace_corpus_corpus_analysis_issue_cluster_path(@workspace, @corpus, @analysis, @cluster)
    end
end
