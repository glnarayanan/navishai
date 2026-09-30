require "test_helper"

class CorpusDiscoveryTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @corpus = workspaces(:acme_support).corpora.create!(name: "Company issues")
    @membership = memberships(:owner_support)
    @records = [
      { id: "a", title: "Nimbus SAML certificate", content: "Nimbus SAML certificate expired. Metadata certificate rotation." },
      { id: "b", title: "Nimbus SAML certificate rotation", content: "Nimbus SAML certificate metadata rotation expired." },
      { id: "c", title: "Delta invoice export", content: "Delta invoice export currency rounding. CSV currency invoice." },
      { id: "rare", title: "Quasar webhook replay", content: "Quasar webhook replay causes data loss. Engineering escalation. Still broken.", context: { impact: "critical" } }
    ]
    @snapshot = intake(@records.to_json)
  end

  test "company terms group related records and critical minority beats volume" do
    analysis = request(1)
    CorpusAnalysisJob.perform_now(analysis.id)
    assert_equal "complete", analysis.reload.state
    assert_equal 4, analysis.summary["conversations"]
    assert_equal 3, analysis.issue_clusters.count
    cluster = analysis.issue_clusters.joins(:cluster_members).where(cluster_members: { corpus_item_id: @snapshot.corpus_items.find_by!(external_id: "a").id }).sole
    assert_equal %w[a b], cluster.cluster_members.joins(:corpus_item).order("corpus_items.external_id").pluck("corpus_items.external_id")
    selected = ClusterMember.selected.where(issue_cluster: analysis.issue_clusters).sole
    assert_equal "rare", selected.corpus_item.external_id
    assert_includes selected.selection_reason, "ahead of volume"
    assert_includes selected.signals, "reported critical impact"
    assert_includes cluster.proposed_label, "certificate"
    assert_no_difference "ClusterMember.count" do
      CorpusAnalysisJob.perform_now(analysis.id)
    end
  end

  test "input versions stay frozen when current source changes before processing" do
    analysis = request(10)
    intake([ { id: "new", title: "New issue", content: "Unrelated product incident" } ].to_json)
    CorpusAnalysisJob.perform_now(analysis.id)
    assert_equal 4, analysis.reload.summary["conversations"]
    assert_equal %w[a b c rare], analysis.corpus_items.order(:external_id).pluck(:external_id)
    assert_equal [ "new" ], @corpus.current_items.pluck(:external_id)
  end

  test "expert taxonomy revisions retain prior judgment and cannot cross analyses" do
    analysis = request(4)
    CorpusAnalysisJob.perform_now(analysis.id)
    cluster = analysis.issue_clusters.first
    first = TaxonomyVersion.review!(analysis:, membership: @membership, cluster_id: cluster.id, label: "Nimbus identity setup")
    second = TaxonomyVersion.review!(analysis:, membership: @membership, cluster_id: cluster.id, label: "SAML certificate expiry")
    assert_equal "Nimbus identity setup", first.reload.labels[cluster.id.to_s]
    assert_equal "SAML certificate expiry", cluster.label
    assert_equal 2, second.number
    assert_raises(ActiveRecord::ReadOnlyRecord) { first.update!(labels: {}) }
    other = request(1)
    assert_raises(ActiveRecord::RecordNotFound) { TaxonomyVersion.review!(analysis: other, membership: @membership, cluster_id: cluster.id, label: "Foreign") }
  end

  test "deleted source removes retained analysis derivatives and expired jobs fail atomically" do
    analysis = request(4)
    travel 366.days do
      CorpusAnalysisJob.perform_now(analysis.id)
      assert_equal "failed", analysis.reload.state
      assert_includes analysis.error, "expired"
      assert_empty analysis.issue_clusters
    end
    SourcePurge.call(source: @snapshot.source, membership: @membership)
    assert_not CorpusAnalysis.exists?(analysis.id)
    assert_empty CorpusAnalysisInput.where(corpus: @corpus)
  end

  test "job checks membership again and foreign input fails SQL relationship" do
    analysis = request(4)
    Membership.create!(workspace: @corpus.workspace, user: users(:teammate), role: :owner)
    @membership.update!(role: :viewer)
    CorpusAnalysisJob.perform_now(analysis.id)
    assert_equal "failed", analysis.reload.state
    assert_empty analysis.issue_clusters
    other = workspaces(:beta_support).corpora.create!(name: "Other evidence")
    foreign = CorpusIntake.call(corpus: other, membership: memberships(:outsider_beta), name: "Other source", kind: "document", bytes: "Other workspace text").corpus_items.sole
    assert_raises(ActiveRecord::InvalidForeignKey) do
      CorpusAnalysisInput.transaction(requires_new: true) do
        analysis.corpus_analysis_inputs.create!(workspace: @corpus.workspace, corpus: @corpus, corpus_item: foreign)
      end
    end
  end

  private
    def request(limit)
      CorpusAnalysis.request!(corpus: @corpus, membership: @membership, scenario_limit: limit)
    end

    def intake(bytes)
      CorpusIntake.call(corpus: @corpus, membership: @membership, name: "History", kind: "conversations", bytes:)
    end
end
