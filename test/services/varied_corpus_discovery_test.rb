require "test_helper"
require "tempfile"
require_relative "../test_helpers/model_discovery_test_helper"

class VariedCorpusDiscoveryTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include ModelDiscoveryTestHelper

  # Known synthetic partitions, not semantic-quality or customer-coverage evidence.
  FAMILIES = {
    "a" => [ 720, "saml federation signing", false ],
    "b" => [ 640, "webhook replay delivery", true ],
    "c" => [ 480, "invoice decimal rounding", true ],
    "d" => [ 360, "検索索引 同期遅延 全文検索", false ]
  }.freeze
  RISK_IDS = %w[a-0718 a-0719].freeze
  SELECTED_IDS = %w[a-0000 a-0718 a-0719 b-0000 c-0000 d-0000].freeze
  RISK_SIGNALS = [ "escalation mention", "reopen / unresolved mention", "risk mention",
    "diagnostic evidence mention", "reported critical impact", "reported reopen" ].freeze

  LARGE_FAMILIES = {
    "a" => [ 30_000, "saml federation signing" ],
    "b" => [ 18_000, "webhook replay delivery" ],
    "c" => [ 12_000, "invoice decimal rounding" ],
    "d" => [ 9_000, "検索索引 同期遅延 全文検索" ],
    "e" => [ 7_000, "oauth scopes consent" ],
    "f" => [ 5_000, "dns resolver nameserver" ],
    "g" => [ 4_000, "cursor pagination offset" ],
    "h" => [ 3_000, "csv delimiter quoting" ],
    "i" => [ 2_500, "cache eviction invalidation" ],
    "j" => [ 2_000, "socket handshake keepalive" ],
    "k" => [ 1_500, "queue dequeue backpressure" ],
    "l" => [ 1_000, "schema migration column" ],
    "m" => [ 800, "replica quorum consensus" ],
    "n" => [ 600, "bucket multipart checksum" ],
    "o" => [ 400, "locale timezone daylight" ],
    "p" => [ 300, "quota throttling capacity" ],
    "q" => [ 250, "encryption cipher keyring" ],
    "r" => [ 200, "vector embedding dimension" ],
    "s" => [ 150, "archive compression gzip" ],
    "t" => [ 2_298, "scheduler cron interval" ]
  }.freeze
  LARGE_RISK_IDS = %w[t-2296 t-2297].freeze

  test "one hundred thousand heterogeneous fixed inputs stream through intake discovery and historical mining" do
    @workspace = workspaces(:acme_support)
    @membership = memberships(:owner_support)
    @corpus = @workspace.corpora.create!(name: "Large varied synthetic engineering proof only")
    assert_equal 20, LARGE_FAMILIES.size
    assert_equal 99_998, LARGE_FAMILIES.values.sum(&:first)
    snapshot = build_large_varied_history
    documents = %w[a d].map do |prefix|
      CorpusIntake.call(corpus: @corpus, membership: @membership, name: "Large known document #{prefix}",
        kind: "document", bytes: LARGE_FAMILIES.fetch(prefix).last)
    end
    expected_ids = LARGE_FAMILIES.flat_map { |prefix, (count, _)| family_ids(prefix, count) }.sort
    selected_ids = (LARGE_FAMILIES.keys.map { |prefix| "#{prefix}-0000" } + LARGE_RISK_IDS).sort
    fixed_ids = snapshot.corpus_items.pluck(:id) + documents.flat_map { |document| document.corpus_items.pluck(:id) }
    assert_equal 100_000, fixed_ids.size
    analysis = CorpusAnalysis.request!(corpus: @corpus, membership: @membership, scenario_limit: 22, processing_method: "local_stream")
    assert_equal CorpusAnalysis::STREAM_METHOD, analysis.processing_method
    assert_equal fixed_ids.sort, analysis.corpus_analysis_inputs.order(:corpus_item_id).pluck(:corpus_item_id)
    assert_enqueued_with(job: CorpusAnalysisJob, args: [ analysis.id ])

    newer = CorpusIntake.call(corpus: @corpus, membership: @membership, name: "Large varied history", kind: "conversations",
      bytes: [ { id: "later", title: "New outage", content: "Security outage engineering", context: { impact: "critical", reopened: true } } ].to_json)
    assert_not_equal snapshot.id, newer.id
    assert_equal newer.id, snapshot.source.reload.current_snapshot_id
    assert_no_corpus_item_materialization { CorpusAnalysisJob.perform_now(analysis.id) }
    assert_equal "complete", analysis.reload.state, analysis.error
    assert_equal({ "conversations" => 99_998, "documents" => 2, "clusters" => 20,
      "selected" => 22, "represented_clusters" => 20, "risk_mentions" => 2,
      "text_window" => 4000, "similarity_threshold" => 0.3 }, analysis.summary)
    members = ClusterMember.where(issue_cluster: analysis.issue_clusters).joins(:corpus_item)
    assert_equal expected_ids, members.order("corpus_items.external_id").pluck("corpus_items.external_id")
    assert_equal snapshot.corpus_items.order(:id).pluck(:id), members.order(:corpus_item_id).pluck(:corpus_item_id)
    assert_equal [ snapshot.id ], members.distinct.pluck("corpus_items.source_snapshot_id")
    assert_equal [ @workspace.id ], members.distinct.pluck("corpus_items.workspace_id")
    assert_equal [ @corpus.id ], members.distinct.pluck("corpus_items.corpus_id")
    assert_equal selected_ids, members.selected.order("corpus_items.external_id").pluck("corpus_items.external_id")
    assert_equal LARGE_RISK_IDS, members.where("cluster_members.signals <> '[]'::jsonb").order("corpus_items.external_id").pluck("corpus_items.external_id")
    LARGE_FAMILIES.each do |prefix, (count, _)|
      cluster = members.find_by!(corpus_items: { external_id: "#{prefix}-0000" }).issue_cluster
      assert_equal family_ids(prefix, count).sort, cluster.cluster_members.joins(:corpus_item).order("corpus_items.external_id").pluck("corpus_items.external_id")
      assert_equal({ "count" => count, "possible_documentation_gap" => !%w[a d].include?(prefix) }, cluster.signals)
    end
    members.selected.includes(:corpus_item).each do |member|
      if LARGE_RISK_IDS.include?(member.corpus_item.external_id)
        assert_equal RISK_SIGNALS, member.signals
        assert_operator member.corpus_item.content.index("data loss"), :>, 4000
        ordinary = snapshot.corpus_items.find_by!(external_id: member.corpus_item.external_id == "t-2296" ? "t-0000" : "t-0001")
        assert_equal ordinary.content.ljust(4000), member.corpus_item.content.first(4000)
        assert_includes member.selection_reason, "Risk / reopen signal prioritised ahead of volume"
      else
        assert_empty member.signals
        assert_includes member.selection_reason, "Nearest to this cluster's term centroid"
      end
      assert_includes member.selection_reason, "Expert review required"
    end

    before_mining = members.selected.order(:corpus_item_id).pluck(:corpus_item_id, :signals, :selection_reason)
    scenarios = ScenarioMining.call(analysis:, membership: @membership)
    assert_equal selected_ids, scenarios.map { |scenario| scenario.corpus_item.external_id }.sort
    assert_equal [ snapshot.id ], scenarios.map { |scenario| scenario.corpus_item.source_snapshot_id }.uniq
    assert_equal [ snapshot.source_id ], scenarios.map { |scenario| scenario.corpus_item.source_snapshot.source_id }.uniq
    assert_equal [ "mined" ], scenarios.map { |scenario| scenario.current_version.origin }.uniq
    assert_equal [ @membership.user.id ], scenarios.map { |scenario| scenario.current_version.created_by_id }.uniq
    assert scenarios.none? { |scenario| scenario.current_version.approved? }
    scenarios.each do |scenario|
      evidence = scenario.current_version.scenario_evidence.sole
      assert_equal scenario.corpus_item_id, evidence.corpus_item_id
      assert_equal scenario.corpus_item.content.first(4000), evidence.excerpt
      assert_equal "expectation", evidence.kind
    end
    assert_no_difference [ "IssueCluster.count", "ClusterMember.count", "Scenario.count", "ScenarioVersion.count", "ScenarioEvidence.count", "AuditEvent.count" ] do
      # The completed job is a no-op, not a second full analysis at another limit.
      CorpusAnalysisJob.perform_now(analysis.id)
      assert_equal scenarios.map(&:id).sort, ScenarioMining.call(analysis:, membership: @membership).map(&:id).sort
    end
    assert_equal before_mining, members.selected.order(:corpus_item_id).pluck(:corpus_item_id, :signals, :selection_reason)
    assert_equal fixed_ids.sort, analysis.corpus_analysis_inputs.order(:corpus_item_id).pluck(:corpus_item_id)
    assert_equal expected_ids, members.order("corpus_items.external_id").pluck("corpus_items.external_id")
  end

  test "varied streaming inputs retain exact partitions reports tied selections and historical mining" do
    @workspace = workspaces(:acme_support)
    @membership = memberships(:owner_support)
    @corpus = @workspace.corpora.create!(name: "Varied synthetic local proof only")
    snapshot = build_varied_history
    documents = [ "saml federation signing", "検索索引 同期遅延 全文検索" ].each_with_index.map do |text, index|
      CorpusIntake.call(corpus: @corpus, membership: @membership, name: "Known document #{index}", kind: "document", bytes: text)
    end
    expected_ids = FAMILIES.flat_map { |prefix, (count, *)| family_ids(prefix, count) } + %w[z-0000 z-0001]
    fixed_ids = snapshot.corpus_items.pluck(:id) + documents.flat_map { |document| document.corpus_items.pluck(:id) }
    analysis = CorpusAnalysis.request!(corpus: @corpus, membership: @membership, scenario_limit: 6, processing_method: "local_stream")
    assert_equal CorpusAnalysis::STREAM_METHOD, analysis.processing_method
    assert_equal fixed_ids.sort, analysis.corpus_analysis_inputs.order(:corpus_item_id).pluck(:corpus_item_id)
    tied = CorpusAnalysis.request!(corpus: @corpus, membership: @membership, scenario_limit: 1, processing_method: "local_stream")

    # Replace current intake before the real job runs: neither discovery nor mining
    # may substitute this newer, differently signalled record for the fixed export.
    newer = CorpusIntake.call(corpus: @corpus, membership: @membership, name: "Varied history", kind: "conversations",
      bytes: [ { id: "later", title: "New outage", content: "Security outage engineering", context: { impact: "critical", reopened: true } } ].to_json)
    assert_not_equal snapshot.id, newer.id
    assert_no_corpus_item_materialization { CorpusAnalysisJob.perform_now(analysis.id) }
    assert_equal "complete", analysis.reload.state, analysis.error
    assert_equal({ "conversations" => 2202, "documents" => 2, "clusters" => 6,
      "selected" => 6, "represented_clusters" => 4, "risk_mentions" => 2,
      "text_window" => 4000, "similarity_threshold" => 0.3 }, analysis.summary)
    members = ClusterMember.where(issue_cluster: analysis.issue_clusters).joins(:corpus_item)
    assert_equal expected_ids.sort, members.order("corpus_items.external_id").pluck("corpus_items.external_id")
    assert_equal [ snapshot.id ], members.distinct.pluck("corpus_items.source_snapshot_id")
    assert_equal SELECTED_IDS, members.selected.order("corpus_items.external_id").pluck("corpus_items.external_id")
    assert_equal RISK_IDS, members.where("cluster_members.signals <> '[]'::jsonb").order("corpus_items.external_id").pluck("corpus_items.external_id")

    FAMILIES.each do |prefix, (count, _terms, gap)|
      cluster = members.find_by!(corpus_items: { external_id: "#{prefix}-0000" }).issue_cluster
      assert_equal family_ids(prefix, count), cluster.cluster_members.joins(:corpus_item).order("corpus_items.external_id").pluck("corpus_items.external_id")
      assert_equal({ "count" => count, "possible_documentation_gap" => gap }, cluster.signals)
      assert_family_reports(cluster, prefix, count)
    end
    %w[z-0000 z-0001].each do |external_id|
      cluster = members.find_by!(corpus_items: { external_id: }).issue_cluster
      assert_equal [ external_id ], cluster.cluster_members.joins(:corpus_item).pluck("corpus_items.external_id")
      assert_equal({ "count" => 1, "possible_documentation_gap" => true }, cluster.signals)
      assert_empty cluster.cluster_members.selected
    end
    members.selected.each do |member|
      external_id = member.corpus_item.external_id
      if RISK_IDS.include?(external_id)
        assert_equal RISK_SIGNALS, member.signals
        assert_includes member.selection_reason, "Risk / reopen signal prioritised ahead of volume"
        assert_operator member.corpus_item.content.index("data loss"), :>, 4000
      else
        assert_empty member.signals
        assert_includes member.selection_reason, "Nearest to this cluster's term centroid"
      end
      assert_includes member.selection_reason, "Expert review required"
    end

    before_mining = members.order(:id).pluck(:corpus_item_id, :signals, :selection_reason)
    scenarios = ScenarioMining.call(analysis:, membership: @membership)
    assert_equal SELECTED_IDS, scenarios.map { |scenario| scenario.corpus_item.external_id }.sort
    assert_equal [ snapshot.id ], scenarios.map { |scenario| scenario.corpus_item.source_snapshot_id }.uniq
    assert scenarios.none? { |scenario| scenario.current_version.approved? }
    assert_equal [ "mined" ], scenarios.map { |scenario| scenario.current_version.origin }.uniq
    assert_equal scenarios.map(&:corpus_item_id).sort, scenarios.flat_map { |scenario| scenario.current_version.scenario_evidence.pluck(:corpus_item_id) }.sort
    assert_no_difference [ "IssueCluster.count", "ClusterMember.count", "Scenario.count", "ScenarioVersion.count" ] do
      CorpusAnalysisJob.perform_now(analysis.id)
      assert_equal scenarios.map(&:id).sort, ScenarioMining.call(analysis:, membership: @membership).map(&:id).sort
    end
    assert_equal before_mining, members.order(:id).pluck(:corpus_item_id, :signals, :selection_reason)
    assert_equal fixed_ids.sort, analysis.corpus_analysis_inputs.order(:corpus_item_id).pluck(:corpus_item_id)
    assert_equal 2202, analysis.reload.summary.fetch("conversations")

    # Identical critical/report/mention priority crosses a one-candidate cutoff;
    # the lower external ID wins, not the latest record or insertion position.
    assert_no_corpus_item_materialization { CorpusAnalysisJob.perform_now(tied.id) }
    assert_equal "complete", tied.reload.state, tied.error
    assert_equal [ "a-0718" ], ClusterMember.selected.where(issue_cluster: tied.issue_clusters).joins(:corpus_item).pluck("corpus_items.external_id")
    assert_equal 1, tied.summary.fetch("represented_clusters")
  end

  private
    def build_large_varied_history
      Tempfile.create([ "navishai-large-varied-", ".jsonl" ]) do |file|
        LARGE_FAMILIES.each do |prefix, (count, terms)|
          # Author-known exclusive technical terms dominate shared integration
          # and four adapter terms. Variant counts differ by at most one; the
          # first variant is always among the most frequent, with stable ID ties.
          # No production tokenizer or scorer supplies these expectations.
          variants = [ "<p>adapter and the 😀</p>", "<div>endpoint the and 🧪</div>", "<span>payload and an 雪</span>", "<b>transport an and 雪</b>" ]
          count.times do |index|
            external_id = format("%s-%04d", prefix, index)
            risk = LARGE_RISK_IDS.include?(external_id)
            # Only the two late risks get padding: their technical vocabulary
            # and surface variant are unchanged inside the clustering window.
            content = "<p>#{(terms + ' ') * 4}</p> integration #{variants[index % 4]}"
            content = content.ljust(4100) + " data loss engineering unresolved logs" if risk
            file.puts(JSON.generate({ id: external_id, title: terms, content:,
              context: { family: prefix, variant: index % 4, impact: risk ? "critical" : "normal", reopened: risk } }))
          end
        end
        file.flush
        assert_operator file.size, :<, 60.megabytes
        digest = Digest::SHA256.file(file.path).hexdigest
        file.define_singleton_method(:read) { |*| raise "Whole-file reads are forbidden" }
        snapshot = CorpusIntake.call(corpus: @corpus, membership: @membership, name: "Large varied history", kind: "conversation_lines", file:)
        assert_equal 99_998, snapshot.corpus_items.count
        assert_equal digest, snapshot.digest
        assert_equal "support-conversation-jsonl-v1", snapshot.processing_version
        assert_equal "conversations", snapshot.source.kind
        assert_equal @membership.user.id, snapshot.imported_by_id
        assert_equal snapshot.id, snapshot.source.current_snapshot_id
        snapshot
      end
    end

    def family_ids(prefix, count)
      count.times.map { |index| format("%s-%04d", prefix, index) }
    end

    def build_varied_history
      snapshot = CorpusIntake.call(corpus: @corpus, membership: @membership, name: "Varied history", kind: "conversations",
        bytes: [ { id: "z-0000", title: "an", content: "<p>and the 12 😀</p>" },
          { id: "z-0001", title: "the", content: "<p>and an 34 😀</p>" } ].to_json)
      connection = ApplicationRecord.connection
      # Bounded SQL inserts inside Rails' disposable test transaction, not uploads
      # that would raise intake limits. No application callbacks per synthetic row.
      # Four equally frequent variants per family have symmetric centroid scores:
      # first fixed external ID wins. Three heavily repeated exclusive terms keep
      # families separate despite shared integration and adapter vocabulary.
      FAMILIES.each do |prefix, (count, terms, _gap)|
        connection.execute(<<~SQL)
          INSERT INTO corpus_items (workspace_id, corpus_id, source_snapshot_id, external_id, title, content, context, created_at)
          SELECT #{@workspace.id}, #{@corpus.id}, #{snapshot.id}, #{connection.quote(prefix + '-')} || lpad(i::text, 4, '0'),
            #{connection.quote(terms)},
            '<p>' || repeat(#{connection.quote(terms + ' ')}, 4) || '</p> integration ' ||
              (ARRAY['adapter', 'endpoint', 'payload', 'transport'])[1 + i % 4] ||
              CASE WHEN #{connection.quote(prefix)} = 'a' AND i >= 718
                THEN repeat(' ', 4100) || 'data loss engineering unresolved logs' ELSE '' END,
            CASE WHEN #{connection.quote(prefix)} = 'a' AND i >= 718
              THEN '{"impact":"critical","reopened":true}'::jsonb
              WHEN i = 0 THEN '{"escalated":true,"failed":true,"reopened":false,"impact":"Critical"}'::jsonb
              WHEN i = 1 THEN '{"escalated":false,"failed":false,"reopened":"true","impact":true}'::jsonb
              WHEN i = 2 THEN '{"escalated":"true","failed":"false","reopened":null}'::jsonb
              WHEN i = 3 THEN '{"escalated":null,"failed":0}'::jsonb
              ELSE '{}'::jsonb END, NOW()
          FROM generate_series(0, #{count - 1}) AS i
        SQL
      end
      snapshot
    end

    def assert_family_reports(cluster, prefix, count)
      groups = cluster.source_groups
      assert_equal count, groups.fetch("All records").count
      %w[escalated failed].each do |field|
        assert_equal [ 1, 1, count - 2 ], [ "true", "false", "missing / nonboolean" ].map { |state| groups.fetch("context.#{field}: #{state}").count }
        assert_equal [ "#{prefix}-0000" ], source_ids(groups.fetch("context.#{field}: true"))
        assert_equal [ "#{prefix}-0001" ], source_ids(groups.fetch("context.#{field}: false"))
      end
      risks = prefix == "a" ? RISK_IDS : []
      assert_equal [ risks.size, 1, count - risks.size - 1 ], [ "true", "false", "missing / nonboolean" ].map { |state| groups.fetch("context.reopened: #{state}").count }
      assert_equal risks, source_ids(groups.fetch("context.reopened: true"))
      assert_equal risks, source_ids(groups.fetch("reported critical impact"))
      # Explicit fixture facts; do not derive expected signals with discovery's
      # tokenizer, cosine routine or signal regular expressions.
      [ "risk mention", "escalation mention", "reopen / unresolved mention", "diagnostic evidence mention" ].each do |signal|
        assert_equal risks, source_ids(groups.fetch(signal))
      end
    end

    def source_ids(relation)
      relation.reorder("corpus_items.external_id").pluck("corpus_items.external_id")
    end
end
