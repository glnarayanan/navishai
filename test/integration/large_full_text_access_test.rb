require "test_helper"
require_relative "../test_helpers/model_discovery_test_helper"

class LargeFullTextAccessTest < ActionDispatch::IntegrationTest
  include ActiveSupport::Testing::ConstantStubbing
  include ModelDiscoveryTestHelper

  setup do
    build_discovery_corpus
    sign_in_as users(:owner)
  end

  test "explicit local v4 retains repair choice scopes writes and gives viewers read-only history" do
    path = workspace_corpus_corpus_analyses_path(@workspace, @corpus)
    get workspace_corpus_path(@workspace, @corpus)
    assert_select "select[name=processing_method] option[value=local][selected]"
    assert_select "select[name=processing_method] option[value=local_large_full_text]", text: "Large full-text · 100,000 / 1 GiB"
    assert_select "p", text: /Complete evidence reads and mining stay within 10 MiB/
    assert_no_difference [ "CorpusAnalysis.count", "CorpusAnalysisInput.count", "AuditEvent.count" ] do
      assert_no_enqueued_jobs do
        [ 0, 101 ].each do |limit|
          post path, params: { processing_method: "local_large_full_text", scenario_limit: limit }
          assert_response :see_other
          follow_redirect!
          assert_select "[role=alert]", text: /previous local request did not start/
          assert_select "select[name=processing_method] option[value=local_large_full_text][selected]"
        end
        post path, params: { processing_method: "local_large_full_text", scenario_limit: 2, corpus_disclose: "1" }
        assert_response :see_other
        assert_includes flash[:alert], "cannot use model settings or disclosure"
        post workspace_corpus_corpus_analyses_path(workspaces(:beta_support), @corpus), params: { processing_method: "local_large_full_text", scenario_limit: 2 }
        assert_response :not_found
      end
    end
    assert_difference "CorpusAnalysis.count", 1 do
      assert_enqueued_with(job: CorpusAnalysisJob) { post path, params: { processing_method: "local_large_full_text", scenario_limit: 2 } }
    end
    analysis = @corpus.corpus_analyses.sole
    assert_equal "tfidf-large-full-text-seed-centroid-selection-v4", analysis.processing_method
    assert_equal({}, analysis.configuration)
    follow_redirect!
    assert_select "[role=status]", text: /No data leaves this deployment/
    assert_select "p", text: /Large full-text local limits: 100,000 complete records \/ 1 GiB/
    CorpusAnalysisJob.perform_now(analysis.id)
    get workspace_corpus_corpus_analysis_path(@workspace, @corpus, analysis)
    assert_response :success
    assert_select "p", text: /the complete text of each conversation/
    assert_select "p", text: /not verified issue-family coverage/
    assert_select "p", text: /unreviewed proposals/
    assert_select "button", text: "Create selected scenarios"
    assert_empty analysis.taxonomy_versions
    get workspace_corpus_corpus_analysis_path(workspaces(:beta_support), @corpus, analysis)
    assert_response :not_found
    Membership.create!(workspace: @workspace, user: users(:teammate), role: :viewer)
    sign_in_as users(:teammate)
    assert_no_difference [ "CorpusAnalysis.count", "Scenario.count", "TaxonomyVersion.count", "AuditEvent.count" ] do
      assert_no_enqueued_jobs do
        get workspace_corpus_corpus_analysis_path(@workspace, @corpus, analysis)
        assert_response :success
        assert_select "p", text: /the complete text/
        assert_select "main form[method=post]", count: 0
        post path, params: { processing_method: "local_large_full_text", scenario_limit: 2 }
        assert_response :forbidden
      end
    end
    travel 366.days do
      sign_in_as users(:teammate)
      get workspace_corpus_corpus_analysis_path(@workspace, @corpus, analysis)
      assert_response :not_found
    end
  end

  test "v4 budget failure has no partial source proposals mining or retry and refresh writes nothing" do
    analysis = CorpusAnalysis.request!(corpus: @corpus, membership: @membership, scenario_limit: 2, processing_method: "local_large_full_text")
    stub_const(CorpusDiscovery, :MAX_TERM_ENTRIES, 1) { CorpusAnalysisJob.perform_now(analysis.id) }
    assert_equal "failed", analysis.reload.state
    assert_empty analysis.issue_clusters
    assert_empty analysis.summary
    assert_no_difference [ "CorpusAnalysis.count", "IssueCluster.count", "ClusterMember.count", "Scenario.count", "AuditEvent.count" ] do
      assert_no_enqueued_jobs do
        2.times do
          get workspace_corpus_corpus_analysis_path(@workspace, @corpus, analysis)
          assert_response :success
          assert_select "[role=alert]", text: /Large full-text local discovery exceeded.*budget/
          assert_select "details.source-record", count: 0
          assert_select "button", text: "Create selected scenarios", count: 0
          assert_select "main form[method=post]", count: 0
          assert_select "a", text: "Refresh result"
        end
      end
    end
  end

  test "oversized complete preview keeps v4 fixed-family recovery without bypassing read limits" do
    add_large_context_sources
    analysis = nil
    assert_no_corpus_item_materialization do
      analysis = CorpusAnalysis.request!(corpus: @corpus, membership: @membership, scenario_limit: 2, processing_method: "local_large_full_text")
      CorpusAnalysisJob.perform_now(analysis.id)
    end
    assert_equal "complete", analysis.reload.state, analysis.error
    assert_no_corpus_item_materialization do
      assert_no_difference [ "Scenario.count", "TaxonomyVersion.count", "AuditEvent.count" ] do
        get workspace_corpus_corpus_analysis_path(@workspace, @corpus, analysis)
      end
    end
    assert_response :success
    assert_select "[role=alert]", text: /complete evidence read exceeds 10 MiB/
    assert_select "details.source-record", count: 0
    assert_select "main form[method=post]", count: 0
    assert_select "#bounded-family-links a", count: analysis.issue_clusters.count
    assert_select "a", text: "Return to the corpus"
    assert_not_includes response.body, "é" * 100
    cluster = analysis.issue_clusters.joins(:cluster_members).find_by!(cluster_members: { corpus_item_id: @items.fetch("login").id })
    get workspace_corpus_corpus_analysis_issue_cluster_path(@workspace, @corpus, analysis, cluster)
    assert_response :success
    assert_select "#family-records > details", count: 1
    assert_includes response.body, @items.fetch("login").content
  end
end
