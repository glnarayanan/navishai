require "test_helper"
require_relative "../test_helpers/relationship_discovery_test_helper"

class CrossBatchRelationshipsTest < ActiveSupport::TestCase
  include RelationshipDiscoveryTestHelper

  setup { build_relationship_corpus }

  test "v3 discovers a new relationship across separate batches without changing originals calls or authority" do
    calls = []
    analysis = nil
    with_relationship_responses(calls:) do
      analysis = request_relationship_analysis
      2.times { CorpusAnalysisJob.perform_now(analysis.id) }
    end
    assert_equal "complete", analysis.reload.state, analysis.error
    assert_equal "support-corpus-batch-v3", analysis.processing_method
    assert analysis.model?
    assert analysis.batch?
    assert analysis.observations?
    assert analysis.relationships?
    assert_equal 3, calls.size
    payloads = calls.map { |request| JSON.parse(request.body) }
    assert_equal %w[support-corpus-v2 support-corpus-v2 support-corpus-merge-v3], payloads.pluck("schema")
    first_ref = "corpus-item-#{@items.fetch('report-0').id}"
    second_ref = "corpus-item-#{@items.fetch('report-99').id}"
    assert payloads.first(2).none? { |payload| [ first_ref, second_ref ].all? { |ref| payload.fetch("records").pluck("reference").include?(ref) } }
    assert_equal 3, analysis.call_plan.fetch("maximum_calls")
    result = analysis.corpus_analysis_result.result
    assert_equal "support-corpus-global-v3", result.fetch("schema")
    receipts = analysis.corpus_discovery_batches.where(phase: "discovery").order(:position).to_a
    assert_equal receipts.reverse.flat_map { |receipt| receipt.result.fetch("observations").reverse }, result.fetch("observations")
    relationship = result.fetch("relationships").sole
    assert_equal "proposed", relationship.fetch("status")
    assert_equal "contradictory_guidance", relationship.fetch("kind")
    assert_equal "Different account scope or dates may explain these reports; an expert must check both.", relationship.fetch("uncertainty")
    assert_equal [ first_ref, second_ref ], relationship.fetch("evidence").pluck("reference")
    assert_equal [ "Agent: Rotate first, then collect expiry.", "Playbook: Collect expiry before rotation." ], relationship.fetch("evidence").pluck("quote")
    assert_equal receipts.map { |receipt| "#{receipt.request_key}/observation/0" }, relationship.fetch("evidence").pluck("observation_ref")
    assert_equal [ 0, 0 ], relationship.fetch("evidence").pluck("evidence_index")
    assert_not_includes result.fetch("candidates").pluck("reference"), second_ref
    assert_equal [ 0, 0, 0, 0 ], [ HumanLabel.count, TaxonomyVersion.count, Scenario.count, TraceScenarioDecision.count ]
    assert_equal analysis.corpus_discovery_batches.order(:position).pluck(:request_key), calls.map { |request| request["Idempotency-Key"] }
  end

  test "v3 consent fixes the version but not more records bytes or calls including one batch" do
    inputs = CorpusAnalysis.current_inputs(corpus: @corpus, model: true, batch: true)
    [ inputs, [ @document, @items.fetch("report-0") ].sort_by(&:id) ].each do |items|
      old = BatchCorpusDiscovery.plan(items, version: BatchCorpusDiscovery::OBSERVATIONS_VERSION)
      plan = BatchCorpusDiscovery.plan(items, version: BatchCorpusDiscovery::RELATIONSHIPS_VERSION)
      assert_equal old.except("schema", "reducer"), plan.except("schema", "reducer")
      assert_equal "support-corpus-batch-v3", plan["schema"]
      assert_not_equal ModelCorpusDiscovery.digest(old), ModelCorpusDiscovery.digest(plan)
      if items.size > 100
        assert_equal "support-corpus-merge-v3", plan["reducer"]
      else
        assert_nil plan["reducer"]
      end
    end
    with_corpus_approval do
      old = batch_plan(version: BatchCorpusDiscovery::OBSERVATIONS_VERSION)
      assert_no_difference [ "CorpusAnalysis.count", "CorpusDiscoveryBatch.count" ] do
        assert_raises(CorpusIntake::Invalid) { request_relationship_analysis(call_plan_digest: ModelCorpusDiscovery.digest(old)) }
      end
    end
    build_discovery_corpus
    calls = []
    with_relationship_responses(calls:) do
      analysis = request_relationship_analysis
      CorpusAnalysisJob.perform_now(analysis.id)
      assert_equal "complete", analysis.reload.state, analysis.error
      assert_equal 1, analysis.call_plan["maximum_calls"]
      assert_nil analysis.call_plan["reducer"]
      assert_equal "support-corpus-v2", analysis.corpus_discovery_batches.sole.result["schema"]
      assert_equal "support-corpus-global-v3", analysis.corpus_analysis_result.result["schema"]
      assert_equal [], analysis.corpus_analysis_result.result["relationships"]
      assert_equal analysis.corpus_discovery_batches.sole.result["observations"], analysis.corpus_analysis_result.result["observations"]
    end
    assert_equal 1, calls.size
  end

  test "relationship anchors reject foreign wrong-batch malformed negative fractional and out-of-range references" do
    analysis, input, response = merge_example
    changes = [
      ->(anchor) { anchor["observation_ref"] = "#{SecureRandom.uuid}/observation/0" },
      ->(anchor) { anchor["observation_ref"] = input["observations"].last["reference"].sub("/0", "/1") },
      ->(anchor) { anchor["observation_ref"] = nil },
      ->(anchor) { anchor["evidence_index"] = -1 },
      ->(anchor) { anchor["evidence_index"] = 0.0 },
      ->(anchor) { anchor["evidence_index"] = "0" },
      ->(anchor) { anchor["evidence_index"] = 2 },
      ->(anchor) { anchor["quote"] = "invented" }
    ]
    changes.each do |change|
      [ 0, 1 ].each do |index|
        invalid = response.deep_dup
        change.call(invalid["relationships"].sole["anchor_refs"][index])
        assert_raises(SupportOutput::Invalid) { BatchCorpusDiscovery.validate_merge!(invalid, analysis:, input:) }
      end
    end
    [ nil, {}, [ nil, 0 ] ].each do |anchors|
      invalid = response.deep_dup
      invalid["relationships"].sole["anchor_refs"] = anchors
      assert_raises(SupportOutput::Invalid) { BatchCorpusDiscovery.validate_merge!(invalid, analysis:, input:) }
    end
    same_batch = response.deep_dup
    same_batch["relationships"].sole["anchor_refs"][1] = same_batch["relationships"].sole["anchor_refs"][0].merge("evidence_index" => 1)
    assert_raises(SupportOutput::Invalid) { BatchCorpusDiscovery.validate_merge!(same_batch, analysis:, input:) }
    same_document = response.deep_dup
    same_document["relationships"].sole["anchor_refs"].each { |anchor| anchor["evidence_index"] = 1 }
    assert_raises(SupportOutput::Invalid) { BatchCorpusDiscovery.validate_merge!(same_document, analysis:, input:) }
    duplicate = response.deep_dup
    duplicate["relationships"].sole["anchor_refs"] *= 2
    assert_raises(SupportOutput::Invalid) { BatchCorpusDiscovery.validate_merge!(duplicate, analysis:, input:) }
  end

  test "raw text kinds status member count anchor count and complete response boundaries refuse rather than trim" do
    analysis, input, response = merge_example
    original = response["relationships"].sole
    [ [], [ original ] * 100 ].each do |relationships|
      bounded = response.merge("relationships" => relationships)
      assert_equal bounded, BatchCorpusDiscovery.validate_merge!(bounded, analysis:, input:)
    end
    [ nil, {}, [ original ] * 101, [ nil ], [ original.merge("status" => "approved") ],
      [ original.merge("kind" => "universal_score") ], [ original.except("uncertainty") ],
      [ original.merge("uncertainty" => " " * 2000) ], [ original.merge("summary" => "x" * 2001) ],
      [ original.merge("summary" => "\0") ], [ original.merge("evidence" => []) ],
      [ original.merge("anchor_refs" => original["anchor_refs"].first(1)) ] ].each do |relationships|
      assert_raises(SupportOutput::Invalid) { BatchCorpusDiscovery.validate_merge!(response.merge("relationships" => relationships), analysis:, input:) }
    end
    exact = response.deep_dup
    exact["relationships"].sole.merge!("summary" => "雪" * 2000, "uncertainty" => "x" * 2000)
    assert_equal exact, BatchCorpusDiscovery.validate_merge!(exact, analysis:, input:)
    expanded_input = input.deep_dup
    fragments = [ [ "Agent:", "Rotate", "first,", "expiry." ], [ "Playbook:", "Collect", "expiry", "rotation." ] ]
    expanded_input["observations"].each_with_index do |entry, index|
      source_ref = entry["definition"]["evidence"].first["reference"]
      entry["definition"]["evidence"] = fragments[index].map { |quote| { "reference" => source_ref, "quote" => quote } }
    end
    sources = analysis.fixed_inputs.to_h { |item| [ "corpus-item-#{item.id}", item.content ] }
    assert ModelCorpusDiscovery.valid_observations?(expanded_input["observations"].pluck("definition"), sources:)
    eight = response.deep_dup
    eight["relationships"].sole["anchor_refs"] = expanded_input["observations"].flat_map do |entry|
      4.times.map { |index| { "observation_ref" => entry["reference"], "evidence_index" => index } }
    end
    assert_equal eight, BatchCorpusDiscovery.validate_merge!(eight, analysis:, input: expanded_input)
    extra = expanded_input["observations"].first.deep_dup
    extra["reference"] = extra["reference"].sub("/0", "/1")
    extra["definition"]["evidence"] = [ { "reference" => "corpus-item-#{@items.fetch('report-0').id}", "quote" => "then" } ]
    expanded_input["observations"] << extra
    nine = eight.deep_dup
    nine["observation_refs"] << extra["reference"]
    nine["relationships"].sole["anchor_refs"] << { "observation_ref" => extra["reference"], "evidence_index" => 0 }
    assert_raises(SupportOutput::Invalid) { BatchCorpusDiscovery.validate_merge!(nine, analysis:, input: expanded_input) }
    wire = response.merge("relationships" => 100.times.map { |index| original.merge("summary" => "Finding #{index}") })
    remaining = 100.kilobytes - wire.to_json.bytesize
    wire["relationships"].each do |relationship|
      count = [ remaining, 2000 - relationship["summary"].length ].min
      relationship["summary"] += "x" * count
      remaining -= count
    end
    assert_equal 0, remaining
    assert_equal 100.kilobytes, wire.to_json.bytesize
    assert_equal wire, BatchCorpusDiscovery.validate_merge!(wire, analysis:, input:)
    wire["relationships"].last["summary"] += "é"
    assert_equal 100.kilobytes + 2, wire.to_json.bytesize
    assert_raises(SupportOutput::Invalid) { BatchCorpusDiscovery.validate_merge!(wire, analysis:, input:) }
  end

  test "invalid final relationship or omitted original never publishes partial global findings or retries" do
    [ ->(response) { response["relationships"] << response["relationships"].sole.merge("uncertainty" => "") },
      ->(response) { response["observation_refs"].pop },
      ->(response) { response["schema"] = BatchCorpusDiscovery::MERGE_OBSERVATIONS_VERSION } ].each do |change|
      calls = []
      with_relationship_responses(calls:, change: ->(response, payload) { change.call(response) if payload["schema"] == BatchCorpusDiscovery::MERGE_RELATIONSHIPS_VERSION }) do
        analysis = request_relationship_analysis
        2.times { CorpusAnalysisJob.perform_now(analysis.id) }
        assert_equal "complete", analysis.reload.state
        assert_equal "error", analysis.corpus_analysis_result.result["decision"]
        assert_nil analysis.corpus_analysis_result.result["relationships"]
        assert_nil analysis.corpus_analysis_result.result["observations"]
        assert_empty analysis.issue_clusters
        assert_equal %w[proposal proposal error], analysis.corpus_discovery_batches.order(:position).pluck(:state)
      end
      assert_equal 3, calls.size
    end
  end

  test "queued revocation and last-call revocation expiry or changed documents discard new relationships" do
    with_corpus_approval do
      analysis = request_relationship_analysis
      ENV["NAVISHAI_CORPUS_ENDPOINTS"] = "[]"
      with_test_method(EvaluationHttp, :perform, ->(*) { flunk "Revoked queued work must not send" }) { 2.times { CorpusAnalysisJob.perform_now(analysis.id) } }
      assert_equal "failed", analysis.reload.state
      assert_nil analysis.corpus_analysis_result
    end
    changes = [ -> { ENV["NAVISHAI_CORPUS_ENDPOINTS"] = "[]" }, -> { @snapshot.source.update!(expires_at: 1.minute.ago) },
      -> { CorpusIntake.call(corpus: @corpus, membership: @membership, name: "Playbook", kind: "document", bytes: "Changed current policy.") } ]
    changes.each do |change|
      build_relationship_corpus
      calls = []
      with_relationship_responses(calls:, after_call: ->(number) { change.call if number == 3 }) do
        analysis = request_relationship_analysis
        2.times { CorpusAnalysisJob.perform_now(analysis.id) }
        assert_equal "failed", analysis.reload.state
        assert_nil analysis.corpus_analysis_result
        assert_empty analysis.issue_clusters
        assert_equal %w[proposal proposal error], analysis.corpus_discovery_batches.order(:position).pluck(:state)
      end
      assert_equal 3, calls.size
    end
  end

  test "reducer abstention cannot publish relationships while original discovery receipts remain inspectable" do
    calls = []
    with_relationship_responses(calls:, change: ->(response, payload) do
      if payload["schema"] == BatchCorpusDiscovery::MERGE_RELATIONSHIPS_VERSION
        response.merge!("decision" => "abstain", "families" => [], "candidate_refs" => [], "observation_refs" => [], "relationships" => [])
      end
    end) do
      analysis = request_relationship_analysis
      2.times { CorpusAnalysisJob.perform_now(analysis.id) }
      assert_equal "abstain", analysis.reload.corpus_analysis_result.result["decision"]
      assert_equal "support-corpus-merge-v3", analysis.corpus_analysis_result.result["schema"]
      assert_empty analysis.issue_clusters
      assert_equal [ 1, 1 ], analysis.corpus_discovery_batches.where(phase: "discovery").order(:position).map { |receipt| receipt.result["observations"].size }
    end
    assert_equal 3, calls.size
  end

  private
    def merge_example
      analysis = nil
      with_relationship_responses do
        analysis = request_relationship_analysis
        CorpusAnalysisJob.perform_now(analysis.id)
      end
      receipts = analysis.corpus_discovery_batches.where(phase: "discovery").order(:position).to_a
      input = BatchCorpusDiscovery.merge_input(receipts, version: BatchCorpusDiscovery::RELATIONSHIPS_VERSION)
      response = relationship_response(input.merge("schema" => BatchCorpusDiscovery::MERGE_RELATIONSHIPS_VERSION))
      [ analysis, input, response ]
    end
end
