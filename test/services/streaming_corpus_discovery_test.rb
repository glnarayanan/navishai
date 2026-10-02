require "test_helper"
require_relative "../test_helpers/model_discovery_test_helper"

class StreamingCorpusDiscoveryTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include ModelDiscoveryTestHelper
  setup { build_discovery_corpus }

  test "100000 fixed records process without source objects and preserve late risk and historical mining" do
    @corpus = @workspace.corpora.create!(name: "Synthetic scale proof, not quality evidence")
    snapshot = CorpusIntake.call(corpus: @corpus, membership: @membership, name: "Scale fixture", kind: "conversations",
      bytes: [ { id: "000000", title: "Certificate metadata expiry", content: "Certificate metadata expiry. " + "x" * 300 } ].to_json)
    # Disposable test transaction only; bulk rows avoid 100000 fixture callbacks.
    ApplicationRecord.connection.execute(<<~SQL)
      INSERT INTO corpus_items (workspace_id, corpus_id, source_snapshot_id, external_id, title, content, context, created_at)
      SELECT #{@workspace.id}, #{@corpus.id}, #{snapshot.id}, lpad(i::text, 6, '0'),
        CASE WHEN i = 99998 THEN 'Quasar webhook replay' ELSE 'Certificate metadata expiry' END,
        CASE WHEN i = 99998 THEN 'Quasar webhook replay.' || repeat(' ', 4100) || ' data loss engineering'
          ELSE 'Certificate metadata expiry. ' || repeat('x', 300) END,
        CASE WHEN i = 99998 THEN '{"impact":"critical","reopened":true}'::jsonb ELSE '{}'::jsonb END, NOW()
      FROM generate_series(1, 99998) AS i
    SQL
    CorpusIntake.call(corpus: @corpus, membership: @membership, name: "Scale document", kind: "document", bytes: "Certificate metadata expiry.")
    scanned = []
    observer = ->(event) { scanned << event.payload[:row_count] if event.payload[:sql].start_with?('SELECT "corpus_items"."id", "corpus_items"."external_id", "corpus_items"."title"') }
    analysis = nil
    assert_no_corpus_item_materialization { analysis = request_stream }
    assert_equal 100_000, analysis.corpus_analysis_inputs.count
    assert_equal CorpusAnalysis::STREAM_METHOD, analysis.processing_method
    assert_no_corpus_item_materialization { assert_raises(CorpusIntake::Invalid) { analysis.fixed_inputs } }
    assert_no_corpus_item_materialization do
      assert_no_enqueued_jobs do
        assert_no_difference "CorpusAnalysis.count" do
          assert_raises(CorpusIntake::Invalid) { CorpusAnalysis.request!(corpus: @corpus, membership: @membership, scenario_limit: 2) }
          assert_raises(CorpusIntake::Invalid) { CorpusAnalysis.current_inputs(corpus: @corpus, model: true, batch: true) }
          CorpusItem.insert_all!([ { workspace_id: @workspace.id, corpus_id: @corpus.id, source_snapshot_id: snapshot.id,
            external_id: "overflow", title: "Extra", content: "Extra complete record", context: {}, created_at: Time.current } ])
          assert_raises(CorpusIntake::Invalid) { request_stream }
        end
      end
    end
    CorpusIntake.call(corpus: @corpus, membership: @membership, name: "Scale fixture", kind: "conversations",
      bytes: [ { id: "later", title: "Later export", content: "Later records cannot enter fixed membership." } ].to_json)
    assert_no_corpus_item_materialization do
      ActiveSupport::Notifications.subscribed(observer, "sql.active_record") { 2.times { CorpusAnalysisJob.perform_now(analysis.id) } }
    end
    assert_equal [ 100 ] * 1000, scanned
    assert_equal "complete", analysis.reload.state
    assert_equal 99_999, analysis.summary.fetch("conversations")
    assert_equal 1, analysis.summary.fetch("documents")
    assert_equal 2, analysis.summary.fetch("clusters")
    assert_equal 2, analysis.summary.fetch("represented_clusters")
    assert_equal 99_999, ClusterMember.where(issue_cluster: analysis.issue_clusters).count
    selected = ClusterMember.selected.where(issue_cluster: analysis.issue_clusters).joins(:corpus_item).order("corpus_items.external_id")
    assert_equal %w[000000 099998], selected.pluck("corpus_items.external_id")
    assert_includes selected.last.signals, "risk mention"
    assert_includes selected.last.signals, "reported critical impact"
    assert_equal [ 99_998, 1 ], analysis.issue_clusters.order(:id).pluck(:signals).map { |signals| signals.fetch("count") }
    scenarios = ScenarioMining.call(analysis:, membership: @membership)
    assert_equal [ snapshot.id ], scenarios.map { |scenario| scenario.corpus_item.source_snapshot_id }.uniq
    assert scenarios.none? { |scenario| scenario.current_version.approved? }
    assert_equal %w[000000 099998], scenarios.map { |scenario| scenario.corpus_item.external_id }.sort
  end

  test "large complete field checks and partial evidence reads use exact UTF8 bytes" do
    add_large_context_sources
    assert_equal 1.gigabyte, CorpusAnalysis::LARGE_MAX_RECORD_BYTES
    analysis = request_stream
    assert_equal [ @items.fetch("login") ], analysis.fixed_inputs(item_ids: [ @items.fetch("login").id ])
    assert_no_corpus_item_materialization { assert_raises(CorpusIntake::Invalid) { analysis.fixed_inputs } }
    bytes = analysis.corpus_items.sum(CorpusAnalysis::RECORD_BYTES_SQL)
    # Exercise both sides of the same SQL byte comparison without allocating 1 GiB.
    with_budget(CorpusAnalysis, :LARGE_MAX_RECORD_BYTES, bytes) do
      assert_no_corpus_item_materialization { assert_equal analysis.corpus_items.order(:id).pluck(:id), CorpusAnalysis.current_inputs(corpus: @corpus, streaming: true, ids_only: true) }
      assert_empty analysis.fixed_inputs(item_ids: [])
    end
    with_budget(CorpusAnalysis, :LARGE_MAX_RECORD_BYTES, bytes - 1) do
      assert_no_corpus_item_materialization { assert_raises(CorpusIntake::Invalid) { analysis.fixed_inputs(item_ids: [ @items.fetch("login").id ]) } }
      assert_no_enqueued_jobs { assert_raises(CorpusIntake::Invalid) { request_stream } }
    end
  end

  test "term vocabulary and comparison budgets accept the exact boundary and fail atomically one below" do
    @corpus = @workspace.corpora.create!(name: "Exact resource boundaries")
    CorpusIntake.call(corpus: @corpus, membership: @membership, name: "Small asymmetric history", kind: "conversations", bytes: [
      { id: "a", title: "Azure certificate", content: "Azure certificate metadata" },
      { id: "b", title: "Azure certificate", content: "Azure certificate rotation" },
      { id: "c", title: "Quasar replay", content: "Quasar replay" }
    ].to_json)
    CorpusIntake.call(corpus: @corpus, membership: @membership, name: "Policy", kind: "document", bytes: "Certificate policy.")
    # 3 + 3 + 2 conversation entries; seven distinct terms including the document.
    # Only b shares terms with an earlier seed; c has no possible seed comparison.
    [ [ :MAX_TERM_ENTRIES, 8 ], [ :MAX_DISTINCT_TERMS, 7 ], [ :MAX_SEED_COMPARISONS, 1 ] ].each do |name, boundary|
      with_budget(CorpusDiscovery, name, boundary) do
        analysis = request_stream
        CorpusAnalysisJob.perform_now(analysis.id)
        assert_equal "complete", analysis.reload.state, "#{name}: #{analysis.error}"
      end
      with_budget(CorpusDiscovery, name, boundary - 1) do
        analysis = request_stream
        assert_no_difference [ "IssueCluster.count", "ClusterMember.count", "CorpusAnalysisResult.count" ] do
          assert_no_enqueued_jobs { 2.times { CorpusAnalysisJob.perform_now(analysis.id) } }
        end
        assert_equal "failed", analysis.reload.state, name.to_s
        assert_includes analysis.error, "budget"
        assert_empty analysis.summary
        original = CorpusAnalysis.request!(corpus: @corpus, membership: @membership, scenario_limit: 2)
        CorpusAnalysisJob.perform_now(original.id)
        assert_equal "complete", original.reload.state
      end
    end
  end

  test "expiry during computation rolls back all proposals and completion audit without retry" do
    analysis = request_stream
    original = CorpusDiscovery.method(:call)
    with_test_method(CorpusDiscovery, :call, ->(attempt) { summary = original.call(attempt); travel 366.days; summary }) do
      assert_no_difference [ "IssueCluster.count", "ClusterMember.count", "AuditEvent.count" ] do
        assert_no_enqueued_jobs { 2.times { CorpusAnalysisJob.perform_now(analysis.id) } }
      end
    end
    assert_equal "failed", analysis.reload.state
    assert_includes analysis.error, "expired"
  ensure
    travel_back
  end

  test "streaming cannot supply model settings or bypass consent and model limits" do
    assert_no_difference [ "CorpusAnalysis.count", "AuditEvent.count" ] do
      assert_no_enqueued_jobs do
        assert_raises(CorpusIntake::Invalid) { request_stream(configuration: discovery_configuration, disclose: true) }
        assert_raises(CorpusIntake::Invalid) { request_model_analysis(disclose: false) }
      end
    end
    assert_equal [ 2000, 10.megabytes ], CorpusAnalysis.request!(corpus: @corpus, membership: @membership, scenario_limit: 2).input_limits
    assert_equal [ 100_000, 1.gigabyte ], request_stream.input_limits
  end

  private
    def request_stream(**options)
      CorpusAnalysis.request!(**{ corpus: @corpus, membership: @membership, scenario_limit: 2, processing_method: "local_stream" }.merge(options))
    end

    def with_budget(owner, name, value)
      original = owner.const_get(name)
      owner.send(:remove_const, name)
      owner.const_set(name, value)
      yield
    ensure
      owner.send(:remove_const, name)
      owner.const_set(name, original)
    end
end
