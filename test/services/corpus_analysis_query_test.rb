require "test_helper"
require "stringio"

class CorpusAnalysisQueryTest < ActiveSupport::TestCase
  include ActiveSupport::Testing::ConstantStubbing

  test "fixed aggregate guards finish with empty statistics on retained table pages" do
    membership = memberships(:owner_support)
    corpus = membership.workspace.corpora.create!(name: "Disposable planner regression")
    snapshot = intake(corpus, membership, 200)
    CorpusAnalysis.request!(corpus:, membership:, scenario_limit: 2, processing_method: "local_stream")
    SourcePurge.call(source: snapshot.source, membership:)

    connection = ApplicationRecord.connection
    # Fixture DELETE and native purge retain pages. A later import can arrive
    # before autovacuum refreshes the empty-table estimates. Do not ANALYZE the
    # new rows: that would conceal the bad nested-loop aggregate plan.
    connection.execute("ANALYZE corpus_items, corpus_analysis_inputs")
    snapshot = intake(corpus, membership, 20_000)
    analysis = CorpusAnalysis.request!(corpus:, membership:, scenario_limit: 2, processing_method: "local_stream")
    stats = connection.select_all("SELECT reltuples, relpages FROM pg_class WHERE relname IN ('corpus_items', 'corpus_analysis_inputs')")
    assert_equal [ 0.0, 0.0 ], stats.map { |row| row.fetch("reltuples") }
    assert stats.all? { |row| row.fetch("relpages").positive? }
    selected = snapshot.corpus_items.where(external_id: %w[row-0 row-19999]).order(:external_id).to_a
    intake(corpus, membership, 1)
    foreign = memberships(:outsider_beta)
    other_corpus = foreign.workspace.corpora.create!(name: "Unrelated planner corpus")
    other_item = intake(other_corpus, foreign, 1).corpus_items.sole
    bytes = 20_000.times.sum { |i| "row-#{i}".bytesize + "Certificate".bytesize + "Certificate metadata expiry.".bytesize + 2 }

    connection.transaction(requires_new: true) do
      connection.execute("SET LOCAL statement_timeout = '5s'")
      assert_equal selected, analysis.fixed_inputs(item_ids: selected.reverse.map(&:id) + [ other_item.id ])
      stub_const(CorpusAnalysis, :LARGE_MAX_ITEMS, 20_000) { assert_empty analysis.fixed_inputs(item_ids: []) }
      stub_const(CorpusAnalysis, :LARGE_MAX_ITEMS, 19_999) { assert_raises(CorpusIntake::Invalid) { analysis.fixed_inputs(item_ids: []) } }
      stub_const(CorpusAnalysis, :LARGE_MAX_RECORD_BYTES, bytes) { assert_empty analysis.fixed_inputs(item_ids: []) }
      stub_const(CorpusAnalysis, :LARGE_MAX_RECORD_BYTES, bytes - 1) { assert_raises(CorpusIntake::Invalid) { analysis.fixed_inputs(item_ids: []) } }
    end
  end

  private
    def intake(corpus, membership, size)
      lines = size.times.map { |i| JSON.generate({ id: "row-#{i}", title: "Certificate", content: "Certificate metadata expiry." }) }.join("\n") + "\n"
      CorpusIntake.call(corpus:, membership:, name: "Native history", kind: "conversation_lines", file: StringIO.new(lines))
    end
end
