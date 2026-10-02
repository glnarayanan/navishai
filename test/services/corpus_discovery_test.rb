require "test_helper"

class CorpusDiscoveryTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include ActiveSupport::Testing::ConstantStubbing

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

  test "explicit full text separates late diagnostic terms without changing the fixed older windows" do
    prefix = "Shared preamble. " + " " * 4100
    snapshot = intake([
      { id: "late-cert", title: "Imported record", content: prefix + "Nacre certificate metadata expiry. " * 20 },
      { id: "late-cursor", title: "Imported record", content: prefix + "Quasar pagination checkpoint discarded. " * 20 }
    ].to_json)
    original = request(2)
    streaming = request(2, processing_method: "local_stream")
    full = request(2, processing_method: "local_full_text")
    intake([ { id: "later", title: "Replacement history", content: "Other company evidence." } ].to_json)
    [ original, streaming, full ].each do |analysis|
      2.times { CorpusAnalysisJob.perform_now(analysis.id) }
      assert_equal "complete", analysis.reload.state, analysis.error
      assert_equal [ snapshot.id ], analysis.corpus_items.pluck(:source_snapshot_id).uniq
      assert_equal 2, ClusterMember.where(issue_cluster: analysis.issue_clusters).count
    end
    assert_equal "tfidf-full-text-seed-centroid-selection-v3", full.processing_method
    assert_equal [ 2000, 10.megabytes ], full.input_limits
    assert_equal "complete", full.summary.fetch("text_window")
    assert_equal 0.3, full.summary.fetch("similarity_threshold")
    partitions = full.issue_clusters.map { |cluster| cluster.cluster_members.joins(:corpus_item).order("corpus_items.external_id").pluck("corpus_items.external_id") }
    assert_equal [ [ "late-cert" ], [ "late-cursor" ] ], partitions.sort
    [ original, streaming ].each do |analysis|
      assert_equal 4000, analysis.summary.fetch("text_window")
      assert_equal [ "late-cert", "late-cursor" ], analysis.issue_clusters.sole.cluster_members.joins(:corpus_item).order("corpus_items.external_id").pluck("corpus_items.external_id")
    end
    assert_equal CorpusAnalysis::METHOD, original.processing_method
    assert_equal CorpusAnalysis::STREAM_METHOD, streaming.processing_method
    scenarios = ScenarioMining.call(analysis: full, membership: @membership)
    assert_equal 2, scenarios.size
    assert_equal [ snapshot.id ], scenarios.map { |scenario| scenario.corpus_item.source_snapshot_id }.uniq
    assert scenarios.all? { |scenario| !scenario.current_version.approved? && scenario.current_version.scenario_reviews.empty? }
    assert_empty full.taxonomy_versions
    assert_raises(ActiveRecord::ReadonlyAttributeError) { full.update!(processing_method: CorpusAnalysis::METHOD) }
  end

  test "full text uses existing resource budgets and rolls back each overflow without retry" do
    intake([
      { id: "a", title: "Azure certificate", content: " " * 4100 + "Azure certificate metadata" },
      { id: "b", title: "Azure certificate", content: " " * 4100 + "Azure certificate rotation" },
      { id: "c", title: "Quasar replay", content: " " * 4100 + "Quasar replay" }
    ].to_json)
    CorpusIntake.call(corpus: @corpus, membership: @membership, name: "Policy", kind: "document", bytes: "Certificate policy.")
    # Eight distinct per-conversation entries, seven union terms including the
    # document, and one shared-term seed comparison. Late terms must count too.
    [ [ :MAX_TERM_ENTRIES, 8 ], [ :MAX_DISTINCT_TERMS, 7 ], [ :MAX_SEED_COMPARISONS, 1 ] ].each do |name, boundary|
      stub_const(CorpusDiscovery, name, boundary) do
        analysis = request(2, processing_method: "local_full_text")
        CorpusAnalysisJob.perform_now(analysis.id)
        assert_equal "complete", analysis.reload.state, "#{name}: #{analysis.error}"
      end
      stub_const(CorpusDiscovery, name, boundary - 1) do
        analysis = request(2, processing_method: "local_full_text")
        assert_no_difference [ "IssueCluster.count", "ClusterMember.count", "CorpusAnalysisResult.count", "AuditEvent.count" ] do
          assert_no_enqueued_jobs { 2.times { CorpusAnalysisJob.perform_now(analysis.id) } }
        end
        assert_equal "failed", analysis.reload.state, name.to_s
        assert_match(/Full-text local discovery exceeded.*budget/, analysis.error)
        assert_empty analysis.summary
      end
    end
  end

  test "full text cannot accept model configuration or disclosure and preserves local writer checks" do
    assert_no_difference [ "CorpusAnalysis.count", "AuditEvent.count" ] do
      assert_no_enqueued_jobs do
        assert_raises(CorpusIntake::Invalid) { request(2, processing_method: "local_full_text", configuration: { "endpoint" => "https://invalid.example/eval" }) }
        assert_raises(CorpusIntake::Invalid) { request(2, processing_method: "local_full_text", disclose: true) }
        Membership.create!(workspace: @corpus.workspace, user: users(:teammate), role: :owner)
        @membership.update!(role: :viewer)
        assert_raises(Current::RoleAccessDenied) { request(2, processing_method: "local_full_text") }
      end
    end
  end

  test "scalar batches keep global frequencies full-text risk and seed-order centroid ties without source objects" do
    records = 110.times.map do |index|
      { id: format("%03d", 110 - index), title: "Nimbus certificate metadata", content: "Nimbus certificate metadata expiry.", context: { reopened: "true", impact: "Critical" } }
    end
    records[107] = { id: "003", title: "Quasar webhook replay", content: "Quasar webhook replay." + " " * 4100 + " data loss engineering", context: { impact: "critical" } }
    snapshot = intake(records.to_json)
    CorpusIntake.call(corpus: @corpus, membership: @membership, name: "Duplicate external ID", kind: "conversations", bytes: [ records.last ].to_json)
    CorpusIntake.call(corpus: @corpus, membership: @membership, name: "Current policy", kind: "document", bytes: "Certificate metadata expiry.")
    analysis = request(2)
    loaded, scanned = [], []
    materialization = ->(event) { loaded << event.payload[:record_count] if event.payload[:class_name] == "CorpusItem" }
    queries = ->(event) { scanned << event.payload[:row_count] if event.payload[:sql].start_with?('SELECT "corpus_items"."id", "corpus_items"."external_id", "corpus_items"."title"') }
    ActiveSupport::Notifications.subscribed(materialization, "instantiation.active_record") do
      ActiveSupport::Notifications.subscribed(queries, "sql.active_record") { 2.times { CorpusAnalysisJob.perform_now(analysis.id) } }
    end
    assert_empty loaded
    assert_equal [ 100, 12 ], scanned
    assert_equal "complete", analysis.reload.state
    assert_equal 111, analysis.summary["conversations"]
    assert_equal 1, analysis.summary["documents"]
    assert_equal 2, analysis.summary["clusters"]
    assert_equal 111, ClusterMember.where(issue_cluster: analysis.issue_clusters).count
    selected = ClusterMember.selected.where(issue_cluster: analysis.issue_clusters).pluck(:corpus_item_id)
    assert_equal [ snapshot.corpus_items.find_by!(external_id: "003").id, snapshot.corpus_items.find_by!(external_id: "001").id ].sort, selected.sort
    common = analysis.issue_clusters.find_by!(signals: { count: 110, possible_documentation_gap: false })
    assert_equal 110, common.cluster_members.count
    assert_not common.cluster_members.pluck(:signals).flatten.include?("reported reopen")
    rare = analysis.issue_clusters.where.not(id: common.id).sole
    assert rare.signals["possible_documentation_gap"]
    assert_includes rare.cluster_members.sole.signals, "risk mention"
    assert_equal 2, analysis.summary["represented_clusters"]
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

  test "selection groups partition actual fixed family members independently of another analysis or newer export" do
    analysis = request(1)
    CorpusAnalysisJob.perform_now(analysis.id)
    other = request(4)
    CorpusAnalysisJob.perform_now(other.id)
    intake([ { id: "new", title: "Later family", content: "New evidence" } ].to_json)
    groups = analysis.selection_groups
    assert_equal 3, groups.fetch("All families").count
    assert_equal 1, groups.fetch("With selected candidates").count
    assert_equal 2, groups.fetch("No selected candidates").count
    selected = groups.fetch("With selected candidates").sole
    assert_equal [ "rare" ], selected.cluster_members.joins(:corpus_item).pluck("corpus_items.external_id")
    assert_equal %w[a b c], ClusterMember.where(issue_cluster: groups.fetch("No selected candidates")).joins(:corpus_item).order("corpus_items.external_id").pluck("corpus_items.external_id")
    assert_empty other.selection_groups.fetch("No selected candidates")
    assert_equal groups.fetch("All families").ids.sort, (groups.fetch("With selected candidates").ids + groups.fetch("No selected candidates").ids).sort
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
    def request(limit, **options)
      CorpusAnalysis.request!(corpus: @corpus, membership: @membership, scenario_limit: limit, **options)
    end

    def intake(bytes)
      CorpusIntake.call(corpus: @corpus, membership: @membership, name: "History", kind: "conversations", bytes:)
    end
end
