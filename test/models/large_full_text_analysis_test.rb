require "test_helper"

class LargeFullTextAnalysisTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @membership = memberships(:owner_support)
    @corpus = @membership.workspace.corpora.create!(name: "Fixed method history")
    @snapshot = CorpusIntake.call(corpus: @corpus, membership: @membership, name: "History", kind: "conversations", bytes: [
      { id: "a", title: "Imported record", content: "Shared preamble. " + " " * 4100 + "Nacre certificate metadata expiry. " * 20 },
      { id: "b", title: "Imported record", content: "Shared preamble. " + " " * 4100 + "Quasar pagination checkpoint discarded. " * 20 }
    ].to_json)
  end

  test "separate immutable v4 retains all previous windows results and membership after source replacement" do
    previous = %w[local local_stream local_full_text].map { |method| request(method) }
    previous.each { |analysis| CorpusAnalysisJob.perform_now(analysis.id) }
    assert_equal [ CorpusAnalysis::METHOD, CorpusAnalysis::STREAM_METHOD, CorpusAnalysis::FULL_TEXT_METHOD ], previous.map(&:processing_method)
    assert_equal [ 4000, 4000, "complete" ], previous.map { |analysis| analysis.reload.summary.fetch("text_window") }
    assert_equal [ 1, 1, 2 ], previous.map { |analysis| analysis.issue_clusters.count }
    history = previous.map { |analysis| [ analysis.attributes, analysis.issue_clusters.order(:id).map(&:attributes),
      ClusterMember.where(issue_cluster: analysis.issue_clusters).order(:id).map(&:attributes) ] }
    large = request("local_large_full_text")
    CorpusIntake.call(corpus: @corpus, membership: @membership, name: "History", kind: "conversations",
      bytes: [ { id: "a", title: "Replacement", content: "Unrelated current history" } ].to_json)
    CorpusAnalysisJob.perform_now(large.id)
    assert_equal "complete", large.reload.state, large.error
    assert_equal "tfidf-large-full-text-seed-centroid-selection-v4", large.processing_method
    assert large.full_text?
    assert large.large?
    assert_not large.streaming?
    assert_not large.model?
    assert_equal "complete", large.summary.fetch("text_window")
    assert_equal [ [ "a" ], [ "b" ] ], large.issue_clusters.map { |cluster| cluster.cluster_members.joins(:corpus_item).pluck("corpus_items.external_id") }.sort
    assert_equal [ @snapshot.id ], large.corpus_items.pluck(:source_snapshot_id).uniq
    assert_equal({}, large.configuration)
    assert_equal({}, large.call_plan)
    assert_nil large.input_digest
    assert_empty large.corpus_discovery_batches
    assert_empty large.taxonomy_versions
    assert_no_difference [ "IssueCluster.count", "ClusterMember.count", "AuditEvent.count" ] do
      [ *previous, large ].each { |analysis| CorpusAnalysisJob.perform_now(analysis.id) }
    end
    assert_equal history, previous.map { |analysis| [ analysis.reload.attributes, analysis.issue_clusters.order(:id).map(&:attributes),
      ClusterMember.where(issue_cluster: analysis.issue_clusters).order(:id).map(&:attributes) ] }
    assert_raises(ActiveRecord::ReadonlyAttributeError) { large.update!(processing_method: CorpusAnalysis::FULL_TEXT_METHOD) }
    assert_raises(ActiveRecord::StatementInvalid) do
      CorpusAnalysis.transaction(requires_new: true) { CorpusAnalysis.where(id: large.id).update_all(processing_method: CorpusAnalysis::FULL_TEXT_METHOD) }
    end
    assert_raises(ActiveRecord::ReadOnlyRecord) { large.corpus_analysis_inputs.first.update!(corpus_item_id: @corpus.current_items.sole.id) }
    assert_equal "tfidf-large-full-text-seed-centroid-selection-v4", large.reload.processing_method
  end

  test "v4 refuses model settings and disclosure before any request write or job" do
    assert_no_difference [ "CorpusAnalysis.count", "CorpusAnalysisInput.count", "AuditEvent.count" ] do
      assert_no_enqueued_jobs do
        [ { configuration: {} }, { disclose: true }, { configuration: { "endpoint" => "https://invalid.example/eval" }, disclose: true } ].each do |options|
          error = assert_raises(CorpusIntake::Invalid) { request("local_large_full_text", **options) }
          assert_includes error.message, "Large full-text local discovery cannot use model settings or disclosure"
        end
        assert_raises(CorpusIntake::Invalid) { CorpusAnalysis.current_inputs(corpus: @corpus, large_full_text: true, model: true) }
      end
    end
  end

  test "writer revocation before the job stops v4 without proposals or a retry" do
    analysis = request("local_large_full_text")
    Membership.create!(workspace: @corpus.workspace, user: users(:teammate), role: :owner)
    @membership.update!(role: :viewer)
    assert_no_difference [ "IssueCluster.count", "ClusterMember.count", "AuditEvent.count" ] do
      assert_no_enqueued_jobs { 2.times { CorpusAnalysisJob.perform_now(analysis.id) } }
    end
    assert_equal "failed", analysis.reload.state
    assert_includes analysis.error, "Workspace access changed"
    assert_empty analysis.summary
    assert_raises(Current::RoleAccessDenied) { request("local_large_full_text") }
  end

  test "v4 uses same-tenant SQL lineage immutable terminal results and existing source purge cascades" do
    analysis = request("local_large_full_text")
    foreign_corpus = workspaces(:beta_support).corpora.create!(name: "Foreign history")
    foreign = CorpusIntake.call(corpus: foreign_corpus, membership: memberships(:outsider_beta), name: "Foreign document",
      kind: "document", bytes: "Foreign source text").corpus_items.sole
    assert_raises(ActiveRecord::InvalidForeignKey) do
      CorpusAnalysisInput.transaction(requires_new: true) do
        CorpusAnalysisInput.insert_all!([ { workspace_id: @corpus.workspace_id, corpus_id: @corpus.id,
          corpus_analysis_id: analysis.id, corpus_item_id: foreign.id } ])
      end
    end
    CorpusAnalysisJob.perform_now(analysis.id)
    assert_equal "complete", analysis.reload.state
    clusters = analysis.issue_clusters
    members = ClusterMember.where(issue_cluster: clusters)
    assert_equal [ @corpus.workspace_id ], members.distinct.pluck(:workspace_id)
    assert_equal [ @corpus.id ], members.distinct.pluck(:corpus_id)
    assert_equal @snapshot.corpus_items.ids.sort, members.order(:corpus_item_id).pluck(:corpus_item_id)
    assert_raises(ActiveRecord::StatementInvalid) do
      CorpusAnalysis.transaction(requires_new: true) { CorpusAnalysis.where(id: analysis.id).update_all(summary: {}) }
    end
    assert_raises(ActiveRecord::StatementInvalid) do
      ClusterMember.transaction(requires_new: true) { members.update_all(selection_reason: "Replacement") }
    end
    assert_raises(ActiveRecord::StatementInvalid) do
      CorpusAnalysisInput.transaction(requires_new: true) { analysis.corpus_analysis_inputs.update_all(corpus_item_id: foreign.id) }
    end
    scenarios = ScenarioMining.call(analysis:, membership: @membership)
    cluster_ids, scenario_ids = clusters.ids, scenarios.map(&:id)
    SourcePurge.call(source: @snapshot.source, membership: @membership)
    assert_not CorpusAnalysis.exists?(analysis.id)
    assert_empty CorpusAnalysisInput.where(corpus_analysis_id: analysis.id)
    assert_empty IssueCluster.where(id: cluster_ids)
    assert_empty ClusterMember.where(issue_cluster_id: cluster_ids)
    assert_empty Scenario.where(id: scenario_ids)
    assert CorpusItem.exists?(foreign.id)
    assert_equal 1, AuditEvent.where(action: "corpus.analysis_requested", subject_type: "CorpusAnalysis", subject_id: analysis.id).count
    assert_equal 1, AuditEvent.where(action: "corpus.analysis_completed", subject_type: "CorpusAnalysis", subject_id: analysis.id).count
  end

  private
    def request(method, **options)
      CorpusAnalysis.request!(corpus: @corpus, membership: @membership, scenario_limit: 2, processing_method: method, **options)
    end
end
