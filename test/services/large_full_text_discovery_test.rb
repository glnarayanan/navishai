require "test_helper"
require "tempfile"
require_relative "../test_helpers/model_discovery_test_helper"

class LargeFullTextDiscoveryTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include ActiveSupport::Testing::ConstantStubbing
  include ModelDiscoveryTestHelper

  FAMILIES = { "a" => [ 720, "saml federation signing" ], "b" => [ 640, "webhook replay delivery" ],
    "c" => [ 480, "invoice decimal rounding" ], "d" => [ 360, "検索索引 同期遅延 全文検索" ] }.freeze

  setup do
    @workspace = workspaces(:acme_support)
    @membership = memberships(:owner_support)
    @corpus = @workspace.corpora.create!(name: "Synthetic complete-text engineering proof")
  end

  test "late diagnostics above both old bounds keep complete global partitions and historical unapproved mining" do
    snapshot = Tempfile.create([ "large-full-text-", ".jsonl" ]) do |file|
      FAMILIES.each do |prefix, (count, words)|
        count.times do |index|
          risk = prefix == "a" && index >= 718
          content = "Shared preamble. " + " " * 5000 + "<p>#{(words + ' ') * 20}</p> integration 😀"
          content += " data loss engineering unresolved logs" if risk
          file.puts(JSON.generate({ id: format("%s-%04d", prefix, index), title: "Imported record", content:,
            context: { impact: risk ? "critical" : "Critical", reopened: risk ? true : "true" } }))
        end
      end
      %w[z-0000 z-0001].each { |id| file.puts(JSON.generate({ id:, title: "an", content: "<p>and the 12 😀</p>" })) }
      file.flush
      assert_operator file.size, :>, 10.megabytes
      digest = Digest::SHA256.file(file.path).hexdigest
      result = intake(file:)
      assert_equal digest, result.digest
      assert_equal "support-conversation-jsonl-v1", result.processing_version
      result
    end
    %w[a d].each do |prefix|
      CorpusIntake.call(corpus: @corpus, membership: @membership, name: "Policy #{prefix}", kind: "document", bytes: FAMILIES.fetch(prefix).last)
    end
    expected = FAMILIES.flat_map { |prefix, (count, _)| count.times.map { |index| format("%s-%04d", prefix, index) } } + %w[z-0000 z-0001]
    fixed_ids = @corpus.current_items.pluck(:id).sort
    assert_equal 2204, fixed_ids.size
    assert_operator @corpus.current_items.sum(CorpusAnalysis::RECORD_BYTES_SQL), :>, 10.megabytes
    assert_no_corpus_item_materialization do
      assert_no_enqueued_jobs do
        assert_no_difference [ "CorpusAnalysis.count", "AuditEvent.count" ] do
          %w[local local_full_text].each { |method| assert_raises(CorpusIntake::Invalid) { request(processing_method: method) } }
        end
      end
    end
    analysis = nil
    assert_no_corpus_item_materialization { analysis = request(scenario_limit: 6) }
    older = request(processing_method: "local_stream", scenario_limit: 6)
    assert_equal fixed_ids, analysis.corpus_analysis_inputs.order(:corpus_item_id).pluck(:corpus_item_id)
    intake(bytes: [ { id: "later", title: "Replacement history", content: "New export cannot replace fixed diagnostics." } ].to_json)
    scanned = []
    observer = ->(event) { scanned << event.payload[:row_count] if event.payload[:sql].start_with?('SELECT "corpus_items"."id", "corpus_items"."external_id", "corpus_items"."title"') }
    assert_no_corpus_item_materialization do
      ActiveSupport::Notifications.subscribed(observer, "sql.active_record") { CorpusAnalysisJob.perform_now(analysis.id) }
    end
    assert_equal [ 100 ] * 22 + [ 4 ], scanned
    assert_equal "complete", analysis.reload.state, analysis.error
    assert_equal({ "conversations" => 2202, "documents" => 2, "clusters" => 6, "selected" => 6,
      "represented_clusters" => 4, "risk_mentions" => 2, "text_window" => "complete", "similarity_threshold" => 0.3 }, analysis.summary)
    members = ClusterMember.where(issue_cluster: analysis.issue_clusters).joins(:corpus_item)
    assert_equal expected.sort, members.order("corpus_items.external_id").pluck("corpus_items.external_id")
    assert_equal [ snapshot.id ], members.distinct.pluck("corpus_items.source_snapshot_id")
    FAMILIES.each do |prefix, (count, _)|
      cluster = members.find_by!(corpus_items: { external_id: "#{prefix}-0000" }).issue_cluster
      assert_equal count.times.map { |index| format("%s-%04d", prefix, index) }, cluster.cluster_members.joins(:corpus_item).order("corpus_items.external_id").pluck("corpus_items.external_id")
      assert_equal({ "count" => count, "possible_documentation_gap" => !%w[a d].include?(prefix) }, cluster.signals)
    end
    selected_ids = %w[a-0000 a-0718 a-0719 b-0000 c-0000 d-0000]
    assert_equal selected_ids, members.selected.order("corpus_items.external_id").pluck("corpus_items.external_id")
    risks = members.where("cluster_members.signals <> '[]'::jsonb")
    assert_equal %w[a-0718 a-0719], risks.order("corpus_items.external_id").pluck("corpus_items.external_id")
    risks.each do |member|
      assert_equal [ "escalation mention", "reopen / unresolved mention", "risk mention", "diagnostic evidence mention", "reported critical impact", "reported reopen" ], member.signals
      assert_operator member.corpus_item.content.index("data loss"), :>, 4000
      assert_includes member.selection_reason, "ahead of volume"
    end
    CorpusAnalysisJob.perform_now(older.id)
    assert_equal "complete", older.reload.state, older.error
    assert_equal 4000, older.summary.fetch("text_window")
    assert_equal [ 1, 1, 2200 ], older.issue_clusters.pluck(:signals).map { |signals| signals.fetch("count") }.sort
    before = older.attributes
    scenarios = ScenarioMining.call(analysis:, membership: @membership)
    assert_equal selected_ids, scenarios.map { |scenario| scenario.corpus_item.external_id }.sort
    assert_equal [ snapshot.id ], scenarios.map { |scenario| scenario.corpus_item.source_snapshot_id }.uniq
    scenarios.each do |scenario|
      assert_not scenario.current_version.approved?
      assert_empty scenario.current_version.scenario_reviews
      text = scenario.corpus_item.content
      excerpt = scenario.current_version.scenario_evidence.sole.excerpt
      if %w[a-0718 a-0719].include?(scenario.corpus_item.external_id)
        assert_equal text.last(4000), excerpt
        assert_equal [ text.length - 4000, 4000 ], scenario.current_version.draft_notes.fetch("evidence")
        assert_includes excerpt, "data loss engineering unresolved logs"
        assert_not_includes text.first(4000), "data loss engineering unresolved logs"
      else
        assert_equal text.first(4000), excerpt
      end
      assert_empty scenario.current_version.known_facts
      assert_equal ScenarioVersion::REQUIREMENT_TYPES.index_with { [] }, scenario.current_version.requirements
    end
    assert_empty analysis.taxonomy_versions
    assert_no_difference [ "IssueCluster.count", "ClusterMember.count", "Scenario.count", "ScenarioVersion.count", "AuditEvent.count" ] do
      [ analysis, older ].each { |attempt| CorpusAnalysisJob.perform_now(attempt.id) }
      assert_equal scenarios.map(&:id).sort, ScenarioMining.call(analysis:, membership: @membership).map(&:id).sort
    end
    assert_equal before, older.reload.attributes
    assert_equal fixed_ids, analysis.corpus_analysis_inputs.order(:corpus_item_id).pluck(:corpus_item_id)
  end

  test "global rarity across scalar batches differs from per-batch clustering" do
    records = [ { id: "a", title: "an", content: " " * 4100 + "Nimbus nacre" }, { id: "b", title: "an", content: " " * 4100 + "Nimbus quasar" } ]
    records += 98.times.map { |index| { id: format("c-%03d", index), title: "an", content: "Cobalt turbine" } }
    records += 100.times.map { |index| { id: format("z-%03d", index), title: "an", content: "Nimbus" } }
    intake(bytes: records.reverse.to_json)
    analysis = request(scenario_limit: 4)
    CorpusAnalysisJob.perform_now(analysis.id)
    assert_equal "complete", analysis.reload.state, analysis.error
    # Across all 200 records Nimbus occurs in 102, the other diagnostic terms in
    # one each. Shared cosine is about 0.04, below 0.3. In only the first batch,
    # Nimbus occurs in 2/100 and the two records would wrongly join (about 0.42).
    assert_equal [ [ "a" ], [ "b" ], 98.times.map { |i| format("c-%03d", i) }, 100.times.map { |i| format("z-%03d", i) } ],
      analysis.issue_clusters.map { |cluster| cluster.cluster_members.joins(:corpus_item).order("corpus_items.external_id").pluck("corpus_items.external_id") }.sort
    assert_equal %w[a b c-000 z-000], ClusterMember.selected.where(issue_cluster: analysis.issue_clusters).joins(:corpus_item).order("corpus_items.external_id").pluck("corpus_items.external_id")
  end

  test "every work cap accepts its exact boundary and atomically refuses one below including late terms" do
    intake(bytes: [ { id: "a", title: "Azure certificate", content: " " * 4100 + "Azure certificate metadata" },
      { id: "b", title: "Azure certificate", content: " " * 4100 + "Azure certificate rotation" },
      { id: "c", title: "Quasar replay", content: " " * 4100 + "Quasar replay" } ].to_json)
    CorpusIntake.call(corpus: @corpus, membership: @membership, name: "Policy", kind: "document", bytes: "Certificate policy")
    # 3 + 3 + 2 entries, seven union terms including the document, one seed
    # comparison. A prefix-only implementation misses metadata and rotation.
    [ [ :MAX_TERM_ENTRIES, 8 ], [ :MAX_DISTINCT_TERMS, 7 ], [ :MAX_SEED_COMPARISONS, 1 ] ].each do |name, boundary|
      stub_const(CorpusDiscovery, name, boundary) do
        analysis = request
        CorpusAnalysisJob.perform_now(analysis.id)
        assert_equal "complete", analysis.reload.state, "#{name}: #{analysis.error}"
      end
      stub_const(CorpusDiscovery, name, boundary - 1) do
        analysis = request
        assert_no_difference [ "IssueCluster.count", "ClusterMember.count", "CorpusAnalysisResult.count", "AuditEvent.count" ] do
          assert_no_enqueued_jobs { 2.times { CorpusAnalysisJob.perform_now(analysis.id) } }
        end
        assert_equal "failed", analysis.reload.state
        assert_match(/Large full-text local discovery exceeded.*budget/, analysis.error)
        assert_empty analysis.summary
      end
    end
  end

  test "one hundred thousand complete inputs process and actual record 100001 refuses before loading or queuing" do
    snapshot = intake(bytes: [ { id: "000000", title: "an", content: "Nimbus nacre" } ].to_json)
    ApplicationRecord.connection.execute(<<~SQL)
      INSERT INTO corpus_items (workspace_id, corpus_id, source_snapshot_id, external_id, title, content, context, created_at)
      SELECT #{@workspace.id}, #{@corpus.id}, #{snapshot.id}, lpad(i::text, 6, '0'), 'an',
        CASE WHEN i = 99999 THEN repeat(' ', 4100) || 'Quasar replay data loss engineering' ELSE 'Nimbus nacre' END,
        CASE WHEN i = 99999 THEN '{"impact":"critical"}'::jsonb ELSE '{}'::jsonb END, NOW()
      FROM generate_series(1, 99999) AS i
    SQL
    analysis = nil
    assert_no_corpus_item_materialization { analysis = request }
    assert_equal 100_000, analysis.corpus_analysis_inputs.count
    assert_equal [ 100_000, 1.gigabyte ], analysis.input_limits
    assert_no_corpus_item_materialization { CorpusAnalysisJob.perform_now(analysis.id) }
    assert_equal "complete", analysis.reload.state, analysis.error
    assert_equal 100_000, analysis.summary.fetch("conversations")
    assert_equal "complete", analysis.summary.fetch("text_window")
    assert_equal [ 1, 99_999 ], analysis.issue_clusters.pluck(:signals).map { |signals| signals.fetch("count") }.sort
    members = ClusterMember.where(issue_cluster: analysis.issue_clusters).joins(:corpus_item)
    assert_equal 100_000, members.count
    assert_equal %w[000000 099999], members.selected.order("corpus_items.external_id").pluck("corpus_items.external_id")
    CorpusItem.insert_all!([ { workspace_id: @workspace.id, corpus_id: @corpus.id, source_snapshot_id: snapshot.id,
      external_id: "overflow", title: "Extra", content: "Whole record", context: {}, created_at: Time.current } ])
    assert_no_corpus_item_materialization do
      assert_no_enqueued_jobs do
        assert_no_difference [ "CorpusAnalysis.count", "CorpusAnalysisInput.count", "AuditEvent.count" ] do
          assert_raises(CorpusIntake::Invalid) { request }
        end
      end
    end
    assert_equal 100_000, analysis.corpus_analysis_inputs.count
  end

  test "UTF8 whole-input and partial evidence byte edges preserve fixed older limits" do
    snapshot = intake(bytes: [ { id: "雪", title: "é", content: "Nimbus nacre", context: { detail: "雪" } },
      { id: "b", title: "第二", content: "Quasar replay", context: { detail: [ false, 0 ] } } ].to_json)
    items = snapshot.corpus_items.order(:external_id).to_a
    bytes = items.sum { |item| item.external_id.bytesize + item.title.bytesize + item.content.bytesize + JSON.generate(item.context).bytesize }
    # PostgreSQL's JSON text adds a space after colon and between array members.
    bytes += 3
    assert_equal bytes, @corpus.current_items.sum(CorpusAnalysis::RECORD_BYTES_SQL)
    assert_equal 1.gigabyte, CorpusAnalysis::LARGE_MAX_RECORD_BYTES
    analysis = nil
    stub_const(CorpusAnalysis, :LARGE_MAX_RECORD_BYTES, bytes) do
      assert_no_corpus_item_materialization { analysis = request }
      assert_empty analysis.fixed_inputs(item_ids: [])
    end
    stub_const(CorpusAnalysis, :LARGE_MAX_RECORD_BYTES, bytes - 1) do
      assert_no_corpus_item_materialization { assert_raises(CorpusIntake::Invalid) { analysis.fixed_inputs(item_ids: [ items.first.id ]) } }
      assert_no_enqueued_jobs { assert_raises(CorpusIntake::Invalid) { request } }
    end
    item_bytes = @corpus.current_items.where(id: items.first.id).sum(CorpusAnalysis::RECORD_BYTES_SQL)
    stub_const(CorpusAnalysis, :MAX_RECORD_BYTES, item_bytes) do
      assert_equal [ items.first ], analysis.fixed_inputs(item_ids: [ items.first.id ])
      assert_no_corpus_item_materialization { assert_raises(CorpusIntake::Invalid) { analysis.fixed_inputs } }
    end
    stub_const(CorpusAnalysis, :MAX_RECORD_BYTES, item_bytes - 1) do
      assert_no_corpus_item_materialization { assert_raises(CorpusIntake::Invalid) { analysis.fixed_inputs(item_ids: [ items.first.id ]) } }
    end
    %w[local local_full_text].each { |method| assert_equal [ 2000, 10.megabytes ], request(processing_method: method).input_limits }
    assert_equal [ 100_000, 1.gigabyte ], request(processing_method: "local_stream").input_limits
  end

  test "post-computation expiry rolls back proposals and completion audit without retry" do
    intake(bytes: [ { id: "a", title: "an", content: " " * 4100 + "Nimbus nacre" } ].to_json)
    analysis = request
    original = CorpusDiscovery.method(:call)
    with_test_method(CorpusDiscovery, :call, ->(attempt) { summary = original.call(attempt); travel 366.days; summary }) do
      assert_no_difference [ "IssueCluster.count", "ClusterMember.count", "AuditEvent.count" ] do
        assert_no_enqueued_jobs { 2.times { CorpusAnalysisJob.perform_now(analysis.id) } }
      end
    end
    assert_equal "failed", analysis.reload.state
    assert_includes analysis.error, "expired"
    assert_empty analysis.summary
  ensure
    travel_back
  end

  private
    def request(**options)
      CorpusAnalysis.request!(**{ corpus: @corpus, membership: @membership, scenario_limit: 2, processing_method: "local_large_full_text" }.merge(options))
    end

    def intake(bytes: nil, file: nil)
      CorpusIntake.call(corpus: @corpus, membership: @membership, name: "History", kind: file ? "conversation_lines" : "conversations", bytes:, file:)
    end
end
