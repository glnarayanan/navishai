require "test_helper"
require_relative "../test_helpers/batch_discovery_test_helper"

class BatchCorpusDiscoveryTest < ActiveSupport::TestCase
  include BatchDiscoveryTestHelper
  setup { build_batch_corpus }

  test "later conversation intake cannot replace the frozen disclosed batch history" do
    calls = []
    changed_snapshot = nil
    intake = ->(number) do
      if number == 1
        changed_snapshot = CorpusIntake.call(corpus: @corpus, membership: @membership, name: "History", kind: "conversations",
          bytes: [ { id: "later", title: "New billing issue", content: "New billing history was not disclosed." } ].to_json)
      end
    end
    with_batch_responses(calls:, after_call: intake) do
      @analysis = request_batch_analysis
      CorpusAnalysisJob.perform_now(@analysis.id)
    end
    assert_equal "complete", @analysis.reload.state
    assert_equal 106, @analysis.summary.fetch("conversations")
    assert_equal 3, calls.size
    later_reference = "corpus-item-#{changed_snapshot.corpus_items.sole.id}"
    assert calls.first(2).none? { |request| JSON.parse(request.body).fetch("records").pluck("reference").include?(later_reference) }
    assert_not @analysis.corpus_items.exists?(changed_snapshot.corpus_items.sole.id)
  end

  test "exact encoded byte boundary counts Unicode escaping wrappers and separators" do
    first, second = @items.values.first(2).map(&:clone)
    first.content = "é" * 64_000 + "<\\&"
    second.content = "b" * 100_000
    items = [ first, second, @document ].sort_by(&:id)
    first.content += "x" * (256.kilobytes - ModelCorpusDiscovery.input(items, bounded: false).to_json.bytesize)
    assert_operator first.content.length, :<=, 100_000
    assert_equal 256.kilobytes, ModelCorpusDiscovery.input(items, bounded: false).to_json.bytesize
    assert_equal 1, BatchCorpusDiscovery.plan(items).fetch("batches").size
    first.content += "é"
    assert_equal 256.kilobytes + 2, ModelCorpusDiscovery.input(items, bounded: false).to_json.bytesize
    batches = BatchCorpusDiscovery.plan(items).fetch("batches")
    assert_equal 2, batches.size
    document_reference = "corpus-item-#{@document.id}"
    assert_equal [ first, second ].map { |item| "corpus-item-#{item.id}" }.sort, batches.flat_map { |batch| batch.fetch("input_refs") - [ document_reference ] }.sort
    assert batches.all? { |batch| batch.fetch("input_refs").include?(document_reference) && batch.fetch("bytes") <= 256.kilobytes }
  end

  test "complete asymmetric batches merge different labels preserve minority risk exact evidence and once-only UUIDs" do
    calls = []
    with_batch_responses(calls:) do
      @analysis = request_batch_analysis
      assert_equal 3, @analysis.call_plan.fetch("maximum_calls")
      2.times { CorpusAnalysisJob.perform_now(@analysis.id) }
    end
    assert_equal "complete", @analysis.reload.state
    assert_equal 3, calls.size
    assert_equal @analysis.corpus_discovery_batches.order(:position).pluck(:request_key), calls.map { |request| request["Idempotency-Key"] }
    assert_equal %w[proposal proposal proposal], @analysis.corpus_discovery_batches.order(:position).pluck(:state)
    payloads = calls.map { |request| JSON.parse(request.body) }
    payloads.first(2).each do |payload|
      assert_includes payload.fetch("records").pluck("reference"), "corpus-item-#{@document.id}"
      assert_operator payload.fetch("records").size, :<=, 100
    end
    assert_equal @items.values.map { |item| "corpus-item-#{item.id}" }.sort, payloads.first(2).flat_map { |payload| payload.fetch("records").reject { |record| record["kind"] == "document" }.pluck("reference") }.sort
    assert_equal 106, @analysis.summary.fetch("conversations")
    assert_equal 2, @analysis.summary.fetch("clusters")
    assert_equal 105, @analysis.issue_clusters.find_by!(proposed_label: "Company identity lifecycle").cluster_members.count
    fixed = @analysis.corpus_analysis_result.result
    assert_equal [ "critical", "high" ], fixed.fetch("candidates").map { |candidate| candidate.dig("scenario", "importance") }
    rare = fixed.fetch("candidates").first
    assert_equal "corpus-item-#{@items.fetch('rare').id}", rare.fetch("reference")
    assert_equal "Destructive delivery", rare.dig("scenario", "taxonomy_label")
    assert_equal "Escalate repeated deletes with data loss to Engineering.", rare.fetch("evidence_links").sole.fetch("quote")
    retained = @analysis.corpus_discovery_batches.where(phase: "discovery").flat_map { |batch| batch.result.fetch("candidates") }
    fixed.fetch("candidates").each do |candidate|
      original = retained.find { |value| value.fetch("reference") == candidate.fetch("reference") }
      assert_equal original.except("scenario"), candidate.except("scenario")
      assert_equal original.fetch("scenario").except("taxonomy_label"), candidate.fetch("scenario").except("taxonomy_label")
    end
    scenarios = ScenarioMining.call(analysis: @analysis, membership: @membership)
    assert_equal 2, scenarios.size
    assert scenarios.none? { |scenario| scenario.current_version.approved? }
    assert_equal @items.fetch("rare").id, scenarios.find { |scenario| scenario.current_version.importance == "critical" }.corpus_item_id
    assert_raises(ActiveRecord::StatementInvalid) do
      CorpusDiscoveryBatch.transaction(requires_new: true) { @analysis.corpus_discovery_batches.first.update_columns(result: { decision: "abstain" }) }
    end
  end

  test "foreign duplicate omitted malformed refs and invented candidates or quotes never publish partial globals" do
    mutations = [
      ->(value) { value["families"][0]["cluster_refs"].pop },
      ->(value) { value["families"][0]["cluster_refs"] << value["families"][0]["cluster_refs"].first },
      ->(value) { value["families"][0]["cluster_refs"][0] = "foreign/cluster/0" },
      ->(value) { value["families"][0]["cluster_refs"] = nil },
      ->(value) { value["candidate_refs"] = [ "invented/candidate/0" ] },
      ->(value) { value["candidate_refs"] << value["candidate_refs"].first },
      ->(value) { value["families"][0]["quote"] = "invented" },
      ->(value) { value["model"] = "other" }
    ]
    mutations.each do |mutation|
      calls = []
      with_batch_responses(calls:, change: ->(value, payload) { mutation.call(value) if payload["schema"] == BatchCorpusDiscovery::MERGE_VERSION }) do
        analysis = request_batch_analysis
        2.times { CorpusAnalysisJob.perform_now(analysis.id) }
        assert_empty analysis.issue_clusters
        assert_equal "error", analysis.reload.corpus_analysis_result.result.fetch("decision")
        assert_empty ScenarioMining.call(analysis:, membership: @membership)
        assert_equal "error", analysis.corpus_discovery_batches.order(:position).last.state
      end
      assert_equal 3, calls.size
    end
  end

  test "abstain and unknown transport outcome block all later requests" do
    calls = []
    with_batch_responses(calls:, change: ->(value, _) { value.merge!("decision" => "abstain", "clusters" => [], "candidates" => []) }) do
      analysis = request_batch_analysis
      2.times { CorpusAnalysisJob.perform_now(analysis.id) }
      assert_equal "abstain", analysis.reload.corpus_analysis_result.result.fetch("decision")
      assert_equal %w[abstain queued queued], analysis.corpus_discovery_batches.order(:position).pluck(:state)
      assert_empty analysis.issue_clusters
    end
    assert_equal 1, calls.size
    with_corpus_approval do
      analysis = request_batch_analysis
      with_test_method(EvaluationHttp, :call, ->(**) { raise EvaluationHttp::Error, "Synthetic unknown outcome" }) do
        2.times { CorpusAnalysisJob.perform_now(analysis.id) }
      end
      assert_equal %w[error queued queued], analysis.reload.corpus_discovery_batches.order(:position).pluck(:state)
      assert_empty analysis.issue_clusters
    end
  end

  test "source access endpoint changes and interruption during unlocked transport stop subsequent calls" do
    changes = [
      ->(analysis) { @snapshot.source.update!(expires_at: 1.minute.ago) },
      ->(analysis) { CorpusIntake.call(corpus: @corpus, membership: @membership, name: "Playbook", kind: "document", bytes: "Changed company policy.") },
      ->(analysis) { ENV["NAVISHAI_CORPUS_ENDPOINTS"] = "[]" },
      ->(analysis) { analysis.interrupt!(membership: @membership) },
      ->(analysis) { Membership.create!(workspace: @workspace, user: users(:teammate), role: :owner); @membership.update!(role: :viewer) }
    ]
    changes.each do |change|
      calls = []
      analysis = nil
      with_batch_responses(calls:, after_call: ->(number) { @corpus.with_lock { change.call(analysis) } if number == 1 }) do
        analysis = request_batch_analysis
        2.times { CorpusAnalysisJob.perform_now(analysis.id) }
      end
      assert_equal 1, calls.size
      assert_equal "failed", analysis.reload.state
      assert_empty analysis.issue_clusters
      assert_equal %w[error queued queued], analysis.corpus_discovery_batches.order(:position).pluck(:state)
      @membership.reload.update!(role: :owner) unless @membership.owner?
      build_batch_corpus
    end
  end

  test "stale consent unsafe settings infeasible documents records and batch bounds queue nothing" do
    with_corpus_approval do
      [ { disclose: false }, { call_plan_digest: "stale" }, { input_digest: "stale" }, { configuration: discovery_configuration.merge("credential" => "not-allowed") } ].each do |options|
        assert_no_difference([ "CorpusAnalysis.count", "CorpusDiscoveryBatch.count" ]) { assert_raises(CorpusIntake::Invalid) { request_batch_analysis(**options) } }
      end
    end
    inputs = CorpusAnalysis.current_inputs(corpus: @corpus, model: true, batch: true)
    huge = @items.values.first.clone
    huge.content = "x" * 256.kilobytes
    assert_raises(CorpusIntake::Invalid) { BatchCorpusDiscovery.plan([ @document, huge ]) }
    assert_raises(CorpusIntake::Invalid) { BatchCorpusDiscovery.plan([ @document ] * 100 + [ inputs.first ]) }
    large = @items.values.first.clone
    large.content = "x" * 130.kilobytes
    assert_raises(CorpusIntake::Invalid) { BatchCorpusDiscovery.plan([ large ] * 31) }
    assert_raises(CorpusIntake::Invalid) { BatchCorpusDiscovery.plan([ large ] * 100) }
    assert_raises(CorpusIntake::Invalid) { BatchCorpusDiscovery.plan([ @items.values.first ] * 2001) }
  end

  test "revocation between retained batches blocks next claim without promoting the first receipt" do
    original = BatchCorpusDiscovery.method(:attempt)
    calls = []
    with_batch_responses(calls:) do
      analysis = request_batch_analysis
      with_test_method(BatchCorpusDiscovery, :attempt, ->(parent, batch, **options, &transport) do
        result = original.call(parent, batch, **options, &transport)
        ENV["NAVISHAI_CORPUS_ENDPOINTS"] = "[]" if batch.position == 1
        result
      end) { CorpusAnalysisJob.perform_now(analysis.id) }
      assert_equal "failed", analysis.reload.state
      assert_equal %w[proposal queued queued], analysis.corpus_discovery_batches.order(:position).pluck(:state)
      assert_empty analysis.issue_clusters
      assert_nil analysis.corpus_analysis_result
      assert_raises(Scenario::Invalid) { ScenarioMining.call(analysis:, membership: @membership) }
    end
    assert_equal 1, calls.size
  end

  test "intermediate reducer bounds reject instead of dropping clusters or candidate evidence" do
    receipt = Struct.new(:request_key, :result)
    cluster = { "label" => "Synthetic", "reason" => "Synthetic", "possible_documentation_gap" => false, "evidence" => [ { "reference" => "corpus-item-1", "quote" => "exact" } ] }
    assert_raises(CorpusIntake::Invalid) { BatchCorpusDiscovery.merge_input([ receipt.new(SecureRandom.uuid, { "clusters" => [ cluster ] * 201, "candidates" => [] }) ]) }
    huge = { "reference" => "corpus-item-1", "scenario" => { "situation" => "x" * 1.megabyte } }
    assert_raises(CorpusIntake::Invalid) { BatchCorpusDiscovery.merge_input([ receipt.new(SecureRandom.uuid, { "clusters" => [ cluster ], "candidates" => [ huge ] }) ]) }
  end

  test "SQL rejects cross-workspace batch definitions" do
    with_corpus_approval do
      analysis = request_batch_analysis
      definition = analysis.corpus_discovery_batches.order(:position).first.attributes.except("id", "request_key")
      assert_raises(ActiveRecord::InvalidForeignKey) do
        CorpusDiscoveryBatch.transaction(requires_new: true) do
          CorpusDiscoveryBatch.create!(definition.merge("workspace_id" => workspaces(:beta_support).id, "position" => 31))
        end
      end
    end
  end

  test "claimed crashed parent cannot resume and deletion cascades fixed batches" do
    with_corpus_approval do
      analysis = request_batch_analysis
      analysis.update!(state: "running", started_at: Time.current)
      batch = analysis.corpus_discovery_batches.order(:position).first
      batch.update!(state: "running", started_at: Time.current)
      with_test_method(EvaluationHttp, :call, ->(**) { flunk "Claimed work must not retry" }) { CorpusAnalysisJob.perform_now(analysis.id) }
      assert_equal "running", batch.reload.state
      ids = analysis.corpus_discovery_batches.pluck(:id)
      analysis.destroy!
      assert_empty CorpusDiscoveryBatch.where(id: ids)
    end
  end
end
