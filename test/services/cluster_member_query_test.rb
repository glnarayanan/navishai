require "test_helper"
require "stringio"
require_relative "../test_helpers/family_evidence_fixture"

class ClusterMemberQueryTest < ActiveSupport::TestCase
  include FamilyEvidenceFixture

  test "retained empty statistics cannot stall complete family evidence" do
    @membership = memberships(:owner_support)
    @workspace = @membership.workspace
    @corpus = @workspace.corpora.create!(name: "Synthetic family query proof")
    snapshot = import_records(200)
    analysis = analyze
    assert_equal 200, ClusterMember.where(issue_cluster: analysis.issue_clusters).count
    SourcePurge.call(source: snapshot.source, membership: @membership)
    connection = ApplicationRecord.connection
    connection.execute("ANALYZE corpus_items, corpus_analysis_inputs, cluster_members")
    stats = connection.select_all("SELECT reltuples, relpages FROM pg_class WHERE relname IN ('corpus_items', 'cluster_members')")
    assert stats.all? { |row| row["reltuples"].zero? && row["relpages"].positive? }

    snapshot = import_records(20_000)
    analysis = analyze
    cluster = analysis.issue_clusters.sole
    expected_ids = snapshot.corpus_items.order(:id).pluck(:id)
    # Later intake must not replace the exact family being inspected.
    import_records(1)
    connection.transaction(requires_new: true) do
      connection.execute("SET LOCAL statement_timeout = '5s'")
      groups = nil
      assert_source_rows_loaded(0) { groups = cluster.source_groups }
      assert_equal 20_000, groups.fetch("All records").count
      assert_equal expected_ids, groups.fetch("All records").pluck(:corpus_item_id)
      assert_equal [ snapshot.id ], groups.fetch("All records").reorder(nil).distinct.pluck("corpus_items.source_snapshot_id")
      assert_equal [ @workspace.id ], groups.fetch("All records").reorder(nil).distinct.pluck("corpus_items.workspace_id")
      assert_equal [ @corpus.id ], groups.fetch("All records").reorder(nil).distinct.pluck("corpus_items.corpus_id")
      assert_equal [ 6667, 6667, 6666 ], %w[true false].push("missing / nonboolean").map { |value| groups.fetch("context.escalated: #{value}").count }
      assert_equal [ expected_ids.last ], groups.fetch("risk mention").pluck(:corpus_item_id)
      assert_equal [ expected_ids.last ], groups.fetch("reported critical impact").pluck(:corpus_item_id)
      assert_equal 20_000, groups.fetch("diagnostic evidence mention").count
      assert_equal expected_ids.last(50), groups.fetch("All records").offset(19_950).limit(50).pluck(:corpus_item_id)
    end
  end

  private
    def import_records(size)
      lines = size.times.map do |index|
        context = { escalated: [ true, false, "true" ][index % 3] }
        content = "Certificate metadata."
        if index == 19_999
          content = content.ljust(4100) + " data loss"
          context[:impact] = "critical"
        end
        JSON.generate({ id: "row-#{index}", title: "Certificate", content:, context: })
      end.join("\n") + "\n"
      CorpusIntake.call(corpus: @corpus, membership: @membership, name: "History", kind: "conversation_lines", file: StringIO.new(lines))
    end

    def analyze
      analysis = CorpusAnalysis.request!(corpus: @corpus, membership: @membership, scenario_limit: 2, processing_method: "local_stream")
      CorpusAnalysisJob.perform_now(analysis.id)
      assert_equal "complete", analysis.reload.state, analysis.error
      analysis
    end
end
