require "test_helper"
require_relative "../test_helpers/model_discovery_test_helper"

class ModelDiscoveryTest < ActiveSupport::TestCase
  include ModelDiscoveryTestHelper
  include ActiveJob::TestHelper
  setup { build_discovery_corpus }

  test "corpus disclosure requires its own purpose consent and exact current preview" do
    previous = ENV["NAVISHAI_SCENARIO_ENDPOINTS"]
    ENV["NAVISHAI_SCENARIO_ENDPOINTS"] = [ { workspace_id: @workspace.id, endpoint: HTTP_ENDPOINT } ].to_json
    with_endpoint_approval do
      assert_no_difference([ "CorpusAnalysis.count", "CorpusAnalysisInput.count" ]) do
        assert_raises(EvaluationHttp::Error) { request_model_analysis }
      end
    end
    with_corpus_approval do
      assert_no_difference([ "CorpusAnalysis.count", "CorpusAnalysisInput.count", "AuditEvent.count" ]) do
        assert_raises(CorpusIntake::Invalid) { request_model_analysis(disclose: false) }
        assert_raises(CorpusIntake::Invalid) { request_model_analysis(configuration: false) }
        assert_raises(CorpusIntake::Invalid) { request_model_analysis(scenario_limit: 21) }
      end
      old_digest = ModelCorpusDiscovery.digest(discovery_input)
      CorpusIntake.call(corpus: @corpus, membership: @membership, name: "Extra policy", kind: "document", bytes: "New source changes disclosure.")
      assert_no_difference([ "CorpusAnalysis.count", "CorpusAnalysisInput.count", "AuditEvent.count" ]) do
        assert_raises(CorpusIntake::Invalid) { request_model_analysis(input_digest: old_digest) }
      end
    end
  ensure
    previous ? ENV["NAVISHAI_SCENARIO_ENDPOINTS"] = previous : ENV.delete("NAVISHAI_SCENARIO_ENDPOINTS")
  end

  test "model byte and record bounds reject rather than silently sampling or truncating" do
    CorpusIntake.call(corpus: @corpus, membership: @membership, name: "History", kind: "conversations",
      bytes: (1..99).map { |number| { id: number.to_s, title: "Conversation #{number}", content: "Complete retained text." } }.to_json)
    assert_equal 100, discovery_input.fetch("records").size
    CorpusIntake.call(corpus: @corpus, membership: @membership, name: "History", kind: "conversations",
      bytes: (1..100).map { |number| { id: number.to_s, title: "Conversation #{number}", content: "Complete retained text." } }.to_json)
    assert_no_corpus_item_materialization { assert_raises(CorpusIntake::Invalid) { discovery_input } }
    CorpusIntake.call(corpus: @corpus, membership: @membership, name: "History", kind: "conversations",
      bytes: (1..3).map { |number| { id: number.to_s, title: "Large #{number}", content: "é" * 45_000 } }.to_json)
    assert_raises(CorpusIntake::Invalid) { discovery_input }
    assert_equal 0, CorpusAnalysis.count
  end

  test "all discovery methods refuse aggregate context before loading complete source rows or queuing" do
    add_large_context_sources
    assert_operator @corpus.current_items.sum("octet_length(content)"), :<, 1.kilobyte
    [ {}, { model: true }, { model: true, batch: true } ].each do |options|
      assert_no_corpus_item_materialization do
        error = assert_raises(CorpusIntake::Invalid) { CorpusAnalysis.current_inputs(corpus: @corpus, **options) }
        assert_includes error.message, "10 MiB"
      end
    end
    assert_no_difference([ "CorpusAnalysis.count", "CorpusAnalysisInput.count", "AuditEvent.count" ]) do
      assert_no_enqueued_jobs do
        assert_no_corpus_item_materialization do
          assert_raises(CorpusIntake::Invalid) { CorpusAnalysis.request!(corpus: @corpus, membership: @membership, scenario_limit: 2) }
        end
      end
    end
  end

  test "previously queued local analysis refuses oversized fixed inputs without proposals or retry" do
    add_large_context_sources
    analysis = build_fixed_analysis
    assert_no_corpus_item_materialization do
      assert_no_difference([ "IssueCluster.count", "ClusterMember.count", "CorpusAnalysisResult.count" ]) do
        2.times { CorpusAnalysisJob.perform_now(analysis.id) }
      end
    end
    assert_equal "failed", analysis.reload.state
    assert_includes analysis.error, "10 MiB"
  end

  test "fixed local model and batch readers cannot bypass aggregate record checks" do
    add_large_context_sources
    [ CorpusAnalysis::METHOD, ModelCorpusDiscovery::VERSION, BatchCorpusDiscovery::VERSION ].each do |method|
      analysis = build_fixed_analysis(processing_method: method)
      assert_no_corpus_item_materialization { assert_raises(CorpusIntake::Invalid) { analysis.fixed_inputs } }
    end
    analysis = build_fixed_analysis(complete: true)
    assert_no_difference([ "Scenario.count", "ScenarioVersion.count", "ScenarioEvidence.count", "AuditEvent.count" ]) do
      assert_no_corpus_item_materialization { assert_raises(CorpusIntake::Invalid) { ScenarioMining.call(analysis:, membership: @membership) } }
    end
  end

  test "exact retained UTF-8 byte boundary preserves complete current and fixed records and ordering" do
    @corpus = @workspace.corpora.create!(name: "Exact record bounds")
    # Each ID/title/text is one byte; PostgreSQL spells this object with one space.
    overhead = 2 * (3 + '{"x": ""}'.bytesize)
    first = "é" * 2.megabytes
    second = "b" * (10.megabytes - overhead - first.bytesize)
    snapshots = [ [ "z", first ], [ "a", second ] ].map do |id, value|
      CorpusIntake.call(corpus: @corpus, membership: @membership, name: id, kind: "conversations",
        bytes: [ { id:, title: "t", content: "c", context: { x: value } } ].to_json)
    end
    items = CorpusAnalysis.current_inputs(corpus: @corpus)
    assert_equal [ "z", "a" ], items.map(&:external_id)
    assert_equal [ first, second ], items.map { |item| item.context.fetch("x") }
    analysis = CorpusAnalysis.request!(corpus: @corpus, membership: @membership, scenario_limit: 1)
    assert_equal [ "a", "z" ], analysis.fixed_inputs.map(&:external_id)
    CorpusIntake.call(corpus: @corpus, membership: @membership, name: "a", kind: "conversations",
      bytes: [ { id: "a", title: "t", content: "c", context: { x: second + "!" } } ].to_json)
    assert_no_corpus_item_materialization { assert_raises(CorpusIntake::Invalid) { CorpusAnalysis.current_inputs(corpus: @corpus) } }
    assert_equal snapshots.map(&:id).sort, analysis.fixed_inputs.map(&:source_snapshot_id).sort
    assert_equal [ second, first ], analysis.fixed_inputs.map { |item| item.context.fetch("x") }
  end

  test "historic conversations remain fixed and foreign corpus sources stay out of requests" do
    calls = []
    with_discovery_response(calls:) do
      analysis = request_model_analysis
      foreign_corpus = @workspace.corpora.create!(name: "Other company dataset")
      CorpusIntake.call(corpus: foreign_corpus, membership: @membership, name: "Foreign evidence", kind: "document", bytes: "FOREIGN CORPUS MUST STAY LOCAL")
      CorpusIntake.call(corpus: @corpus, membership: @membership, name: "History", kind: "conversations", bytes: [ { id: "later", title: "Later export", content: "LATER SNAPSHOT MUST STAY LOCAL" } ].to_json)
      CorpusAnalysisJob.perform_now(analysis.id)
      assert_equal "complete", analysis.reload.state
      assert_equal 3, analysis.summary["conversations"]
      assert_not_includes calls.sole.body, "FOREIGN CORPUS MUST STAY LOCAL"
      assert_not_includes calls.sole.body, "LATER SNAPSHOT MUST STAY LOCAL"
      assert_includes calls.sole.body, "Federation assertion rejected after trust bundle refresh."
      assert_equal 3, analysis.corpus_items.where(source_snapshot: @snapshot).count
    end
  end

  test "changed policy and revoked purpose prevent retaining a response and never retry" do
    calls = []
    with_discovery_response(calls:) do
      analysis = request_model_analysis
      CorpusIntake.call(corpus: @corpus, membership: @membership, name: "Playbook", kind: "document", bytes: "Changed company policy.")
      2.times { CorpusAnalysisJob.perform_now(analysis.id) }
      assert_equal "failed", analysis.reload.state
      assert_includes analysis.error, "documentation changed"
      assert_empty calls
      assert_nil analysis.corpus_analysis_result
    end
    with_corpus_approval do
      analysis = request_model_analysis
      response = discovery_response
      with_test_method(ModelCorpusDiscovery, :call, ->(*) { ENV["NAVISHAI_CORPUS_ENDPOINTS"] = "[]"; response }) { CorpusAnalysisJob.perform_now(analysis.id) }
      assert_equal "failed", analysis.reload.state
      assert_empty analysis.issue_clusters
      assert_nil analysis.corpus_analysis_result
      CorpusAnalysisJob.perform_now(analysis.id)
      assert_empty analysis.issue_clusters
    end
  end

  test "definition result and terminal summary are SQL immutable and purge removes retained copies" do
    with_discovery_response do
      analysis = request_model_analysis
      CorpusAnalysisJob.perform_now(analysis.id)
      result = analysis.reload.corpus_analysis_result
      [ "UPDATE corpus_analyses SET scenario_limit = 3 WHERE id = #{analysis.id}",
        "UPDATE corpus_analyses SET summary = '{}'::jsonb WHERE id = #{analysis.id}",
        "UPDATE corpus_analysis_results SET result = '{}'::jsonb WHERE id = #{result.id}" ].each do |sql|
        assert_raises(ActiveRecord::StatementInvalid) { ApplicationRecord.transaction(requires_new: true) { ApplicationRecord.connection.execute(sql) } }
      end
      assert_raises(ActiveRecord::ReadOnlyRecord) { result.update!(result: result.result.merge("reason" => "Attempted rewrite")) }
      SourcePurge.call(source: @snapshot.source, membership: @membership)
      assert_not CorpusAnalysis.exists?(analysis.id)
      assert_not CorpusAnalysisResult.exists?(result.id)
      assert_empty ClusterMember.where(corpus: @corpus)
    end
  end

  test "access expiry and explicit interruption stop queued work without a call" do
    calls = []
    with_discovery_response(calls:) do
      analysis = request_model_analysis
      analysis.interrupt!(membership: @membership)
      CorpusAnalysisJob.perform_now(analysis.id)
      assert_equal "failed", analysis.reload.state
      assert_empty calls
      second = request_model_analysis
      travel 366.days do
        CorpusAnalysisJob.perform_now(second.id)
        assert_equal "failed", second.reload.state
        assert_includes second.error, "expired"
      end
      third = request_model_analysis
      Membership.create!(workspace: @workspace, user: users(:teammate), role: :owner)
      @membership.update!(role: :viewer)
      CorpusAnalysisJob.perform_now(third.id)
      assert_equal "failed", third.reload.state
      assert_empty calls
    end
  end
end
