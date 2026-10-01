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
    assert_raises(CorpusIntake::Invalid) { BatchCorpusDiscovery.merge_input([ receipt.new(SecureRandom.uuid, { "schema" => ModelCorpusDiscovery::VERSION, "clusters" => [ cluster ] * 201, "candidates" => [] }) ]) }
    huge = { "reference" => "corpus-item-1", "scenario" => { "situation" => "x" * 1.megabyte } }
    assert_raises(CorpusIntake::Invalid) { BatchCorpusDiscovery.merge_input([ receipt.new(SecureRandom.uuid, { "schema" => ModelCorpusDiscovery::VERSION, "clusters" => [ cluster ], "candidates" => [ huge ] }) ]) }
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

  test "v2 fixes the protocol in consent without changing allocation or maximum calls including a single batch" do
    inputs = CorpusAnalysis.current_inputs(corpus: @corpus, model: true, batch: true)
    [ inputs, [ @items.values.first, @document ].sort_by(&:id) ].each do |items|
      legacy = BatchCorpusDiscovery.plan(items)
      plan = BatchCorpusDiscovery.plan(items, version: BatchCorpusDiscovery::OBSERVATIONS_VERSION)
      assert_equal legacy.slice("batches", "source_digest", "maximum_calls"), plan.slice("batches", "source_digest", "maximum_calls")
      assert_equal "support-corpus-batch-v2", plan.fetch("schema")
      assert_equal "support-corpus-v2", plan.fetch("discovery_schema")
      assert_not_equal ModelCorpusDiscovery.digest(legacy), ModelCorpusDiscovery.digest(plan)
      if legacy.fetch("reducer")
        assert_equal "support-corpus-merge-v2", plan.fetch("reducer")
      else
        assert_nil plan.fetch("reducer")
      end
    end
    assert_raises(CorpusIntake::Invalid) { BatchCorpusDiscovery.plan(inputs, version: "support-corpus-batch-v999") }
  end

  test "v2 composes every asymmetric observation including unselected and shared document findings exactly once" do
    analysis = build_observation_batch_analysis
    calls = []
    with_observation_batch_analysis(analysis) do
      with_observation_batch_responses(calls:) do
        result = BatchCorpusDiscovery.execute(analysis)
        analysis.corpus.with_lock { ModelCorpusDiscovery.persist!(analysis, result) }
        assert_raises(CorpusIntake::Invalid) { BatchCorpusDiscovery.execute(analysis) }
      end
    end
    assert_equal 3, calls.size
    assert_equal analysis.corpus_discovery_batches.order(:position).pluck(:request_key), calls.map { |request| request["Idempotency-Key"] }
    payloads = calls.map { |request| JSON.parse(request.body) }
    assert_equal %w[support-corpus-v2 support-corpus-v2 support-corpus-merge-v2], payloads.pluck("schema")
    receipts = analysis.corpus_discovery_batches.where(phase: "discovery").order(:position).to_a
    assert_equal [ 2, 3 ], receipts.map { |receipt| receipt.result.fetch("observations").size }
    expected = receipts.reverse.flat_map { |receipt| receipt.result.fetch("observations").reverse }
    retained = analysis.corpus_analysis_result.result
    assert_equal expected, retained.fetch("observations")
    assert_equal 2, retained.fetch("candidates").size
    unselected = payloads.first.fetch("records").select { |record| record["kind"] == "conversations" }.second.fetch("reference")
    assert_not_includes retained.fetch("candidates").pluck("reference"), unselected
    assert retained.fetch("observations").any? { |observation| observation.fetch("evidence").pluck("reference").include?(unselected) }
    reducer = payloads.last
    assert_equal receipts.flat_map { |receipt| receipt.result.fetch("observations") }, reducer.fetch("observations").pluck("definition")
    assert_equal 2, retained.fetch("observations").count { |observation| observation["summary"] == "Shared playbook escalation needs review." }
    assert_equal 0, HumanLabel.count
    assert_equal 0, TaxonomyVersion.count
    assert_equal 0, Scenario.count
    assert_equal %w[proposal proposal proposal], analysis.corpus_discovery_batches.order(:position).pluck(:state)
  end

  test "v2 aggregate may exceed a single response bound but each discovery remains bounded" do
    analysis = build_observation_batch_analysis
    calls = []
    with_observation_batch_analysis(analysis) do
      with_observation_batch_responses(calls:, change: ->(response, payload) do
        next unless payload["schema"] == ModelCorpusDiscovery::OBSERVATIONS_VERSION
        count = payload.fetch("records").size > 20 ? 100 : 7
        original = response.fetch("observations").first
        response["observations"] = count.times.map { |index| original.merge("summary" => "Fixture finding #{index} for #{original.dig('evidence', 0, 'reference')}") }
      end) do
        result = BatchCorpusDiscovery.execute(analysis)
        assert_equal 107, result.fetch("observations").size
        retained = analysis.corpus_discovery_batches.where(phase: "discovery").order(:position).flat_map { |batch| batch.result.fetch("observations") }
        assert_equal retained.reverse, result.fetch("observations")
      end
    end
    assert_equal 3, calls.size
    analysis = build_observation_batch_analysis
    calls = []
    with_observation_batch_analysis(analysis) do
      with_observation_batch_responses(calls:, change: ->(response, _) { response["observations"] = [ response.fetch("observations").first ] * 101 }) do
        result = BatchCorpusDiscovery.execute(analysis)
        assert_equal "error", result.fetch("decision")
        assert_equal %w[error queued queued], analysis.corpus_discovery_batches.order(:position).pluck(:state)
        assert_empty analysis.issue_clusters
      end
    end
    assert_equal 1, calls.size
  end

  test "v2 single batch keeps its exact observations without a reducer and empty findings do not require one" do
    build_discovery_corpus
    analysis = build_observation_batch_analysis
    calls = []
    with_observation_batch_analysis(analysis) do
      with_observation_batch_responses(calls:) do
        result = BatchCorpusDiscovery.execute(analysis)
        assert_equal analysis.corpus_discovery_batches.sole.result, result
        assert_equal 3, result.fetch("observations").size
      end
    end
    assert_equal 1, calls.size
    assert_equal 1, analysis.call_plan.fetch("maximum_calls")
    assert_nil analysis.call_plan.fetch("reducer")
    build_batch_corpus
    analysis = build_observation_batch_analysis
    calls = []
    with_observation_batch_analysis(analysis) do
      with_observation_batch_responses(calls:, change: ->(response, payload) do
        response["observations"] = [] if payload["schema"] == ModelCorpusDiscovery::OBSERVATIONS_VERSION
      end) do
        result = BatchCorpusDiscovery.execute(analysis)
        assert_equal [], result.fetch("observations")
      end
    end
    assert_equal 3, calls.size
    assert_equal [], JSON.parse(calls.last.body).fetch("observations")
  end

  test "invalid or undisclosed observations in either batch stop later calls and never publish a partial global result" do
    [ [ 1, false ], [ 2, false ], [ 1, true ], [ 2, true ] ].each do |invalid_batch, undisclosed|
      analysis = build_observation_batch_analysis
      calls = []
      with_observation_batch_analysis(analysis) do
        with_observation_batch_responses(calls:, change: ->(response, _) do
          next unless calls.size == invalid_batch
          evidence = response.fetch("observations").last.fetch("evidence").last
          if undisclosed
            other_batch_item = @items.fetch(invalid_batch == 1 ? "rare" : "identity-0")
            evidence.merge!("reference" => "corpus-item-#{other_batch_item.id}", "quote" => other_batch_item.content)
          else
            evidence["quote"] = "Fabricated final quote"
          end
        end) do
          response = BatchCorpusDiscovery.execute(analysis)
          assert_equal "error", response.fetch("decision")
          analysis.corpus.with_lock { ModelCorpusDiscovery.persist!(analysis, response) }
          assert_raises(CorpusIntake::Invalid) { BatchCorpusDiscovery.execute(analysis) }
        end
      end
      assert_equal invalid_batch, calls.size
      assert_empty analysis.issue_clusters
      assert_nil analysis.corpus_analysis_result.result["observations"]
      assert_equal invalid_batch == 1 ? %w[error queued queued] : %w[proposal error queued], analysis.corpus_discovery_batches.order(:position).pluck(:state)
    end
  end

  test "v2 reducer rejects omission duplication foreign malformed and rewritten observations on every side" do
    changes = [
      ->(value) { value.delete("observation_refs") },
      ->(value) { value["observation_refs"] = nil },
      ->(value) { value["observation_refs"] = [] },
      ->(value) { value["observations"] = [ { "summary" => "Invented combined truth" } ] },
      ->(value) { value["schema"] = BatchCorpusDiscovery::MERGE_VERSION },
      ->(value) { value.merge!("decision" => "abstain", "families" => [], "candidate_refs" => []) }
    ]
    [ 0, 2, 4 ].each do |index|
      changes << ->(value) { value["observation_refs"].delete_at(index) }
      changes << ->(value) { value["observation_refs"][index] = "foreign/observation/0" }
      changes << ->(value) { value["observation_refs"][index] = nil }
      changes << ->(value) { value["observation_refs"][index] = value["observation_refs"][(index + 1) % 5] }
    end
    changes.each do |change|
      analysis = build_observation_batch_analysis
      calls = []
      with_observation_batch_analysis(analysis) do
        with_observation_batch_responses(calls:, change: ->(response, payload) { change.call(response) if payload["schema"] == BatchCorpusDiscovery::MERGE_OBSERVATIONS_VERSION }) do
          result = BatchCorpusDiscovery.execute(analysis)
          assert_equal "error", result.fetch("decision")
          analysis.corpus.with_lock { ModelCorpusDiscovery.persist!(analysis, result) }
        end
      end
      assert_equal 3, calls.size
      assert_equal %w[proposal proposal error], analysis.corpus_discovery_batches.order(:position).pluck(:state)
      assert_empty analysis.issue_clusters
      assert_nil analysis.corpus_analysis_result.result["observations"]
    end
  end

  test "v2 discovery and reducer abstention publish no observations and do not resume" do
    [ 1, 3 ].each do |abstaining_call|
      analysis = build_observation_batch_analysis
      calls = []
      with_observation_batch_analysis(analysis) do
        with_observation_batch_responses(calls:, change: ->(response, payload) do
          next unless calls.size == abstaining_call
          response["decision"] = "abstain"
          if payload["schema"] == BatchCorpusDiscovery::MERGE_OBSERVATIONS_VERSION
            response.merge!("families" => [], "candidate_refs" => [], "observation_refs" => [])
          else
            response.merge!("clusters" => [], "candidates" => [], "observations" => [])
          end
        end) do
          result = BatchCorpusDiscovery.execute(analysis)
          assert_equal "abstain", result.fetch("decision")
          analysis.corpus.with_lock { ModelCorpusDiscovery.persist!(analysis, result) }
          assert_raises(CorpusIntake::Invalid) { BatchCorpusDiscovery.execute(analysis) }
        end
      end
      assert_equal abstaining_call, calls.size
      assert_empty analysis.issue_clusters
      if abstaining_call == 1
        assert_equal [], analysis.corpus_analysis_result.result["observations"]
      else
        assert_nil analysis.corpus_analysis_result.result["observations"]
      end
    end
  end

  test "v2 reduction refuses mixed historic protocols and excessive exact observation bytes" do
    analysis = build_observation_batch_analysis
    with_observation_batch_analysis(analysis) { with_observation_batch_responses { BatchCorpusDiscovery.execute(analysis) } }
    receipts = analysis.corpus_discovery_batches.where(phase: "discovery").order(:position).to_a
    assert_raises(CorpusIntake::Invalid) { BatchCorpusDiscovery.merge_input(receipts) }
    legacy_response = merge_response(BatchCorpusDiscovery.merge_input(receipts, version: BatchCorpusDiscovery::OBSERVATIONS_VERSION))
    assert_raises(CorpusIntake::Invalid) { BatchCorpusDiscovery.compose(legacy_response, receipts) }
    legacy_receipt = Struct.new(:request_key, :result).new(SecureRandom.uuid, receipts.first.result.except("observations").merge("schema" => ModelCorpusDiscovery::VERSION))
    assert_raises(CorpusIntake::Invalid) { BatchCorpusDiscovery.merge_input([ legacy_receipt, receipts.last ], version: BatchCorpusDiscovery::OBSERVATIONS_VERSION) }
    assert_raises(CorpusIntake::Invalid) { BatchCorpusDiscovery.compose(legacy_response.merge("schema" => BatchCorpusDiscovery::MERGE_OBSERVATIONS_VERSION), [ legacy_receipt ]) }
    large = { "kind" => "escalation", "status" => "proposed", "summary" => "é" * 2000, "uncertainty" => "é" * 2000,
      "evidence" => [ { "reference" => "corpus-item-1", "quote" => "é" * 2000 } ] }
    receipt = Struct.new(:request_key, :result)
    oversized = receipts.map { |batch| receipt.new(batch.request_key, batch.result.merge("observations" => [ large ] * 100)) }
    assert_raises(CorpusIntake::Invalid) { BatchCorpusDiscovery.merge_input(oversized, version: BatchCorpusDiscovery::OBSERVATIONS_VERSION) }
  end

  test "v2 guards source expiry during transport without retaining observations or continuing" do
    analysis = build_observation_batch_analysis
    calls = []
    with_observation_batch_analysis(analysis) do
      with_observation_batch_responses(calls:, change: ->(_, _) { @snapshot.source.update!(expires_at: 1.minute.ago) }) do
        assert_raises(CorpusIntake::Invalid) { BatchCorpusDiscovery.execute(analysis) }
      end
    end
    assert_equal 1, calls.size
    assert_equal %w[error queued queued], analysis.corpus_discovery_batches.order(:position).pluck(:state)
    assert_nil analysis.corpus_analysis_result
    assert_empty analysis.issue_clusters
    assert_nil analysis.corpus_discovery_batches.order(:position).first.result["observations"]
  end

  private

  def build_observation_batch_analysis
    inputs = CorpusAnalysis.current_inputs(corpus: @corpus, model: true, batch: true)
    plan = BatchCorpusDiscovery.plan(inputs, version: BatchCorpusDiscovery::OBSERVATIONS_VERSION)
    analysis = @corpus.corpus_analyses.create!(workspace: @workspace, requested_by: @membership.user,
      processing_method: BatchCorpusDiscovery::OBSERVATIONS_VERSION, configuration: discovery_configuration,
      input_digest: plan.fetch("source_digest"), call_plan: plan, scenario_limit: 2, state: "running", started_at: Time.current)
    inputs.each { |item| analysis.corpus_analysis_inputs.create!(workspace: @workspace, corpus: @corpus, corpus_item: item) }
    plan.fetch("batches").each do |definition|
      analysis.corpus_discovery_batches.create!(workspace: @workspace, corpus: @corpus, **definition.except("bytes").symbolize_keys, created_at: Time.current)
    end
    refs = analysis.corpus_discovery_batches.order(:position).pluck(:request_key).map(&:to_s)
    if plan.fetch("reducer")
      analysis.corpus_discovery_batches.create!(workspace: @workspace, corpus: @corpus, phase: "reducer", position: refs.size + 1,
        input_refs: refs, input_digest: ModelCorpusDiscovery.digest(plan.fetch("batches").pluck("input_digest")), created_at: Time.current)
    end
    analysis
  end

  # Shared version registration belongs to the lead. Supply only that selection
  # here; the real processing, authority, allocation and receipt guards still run.
  def with_observation_batch_analysis(analysis)
    plan = BatchCorpusDiscovery.method(:plan)
    with_test_method(analysis, :model?, -> { true }) do
      with_test_method(analysis, :batch?, -> { true }) do
        with_test_method(BatchCorpusDiscovery, :plan, ->(items, version: BatchCorpusDiscovery::OBSERVATIONS_VERSION) { plan.call(items, version:) }) do
          with_corpus_approval { yield }
        end
      end
    end
  end

  def with_observation_batch_responses(calls: [], change: nil)
    with_test_method(Resolv, :getaddresses, ->(*) { [ "93.184.216.34" ] }) do
      with_test_method(EvaluationHttp, :perform, ->(_uri, request, _address) do
        payload = JSON.parse(request.body)
        calls << request
        if payload["schema"] == BatchCorpusDiscovery::MERGE_OBSERVATIONS_VERSION
          response = merge_response(payload).merge("schema" => BatchCorpusDiscovery::MERGE_OBSERVATIONS_VERSION,
            "observation_refs" => payload.fetch("observations").pluck("reference").reverse)
        else
          response = batch_response(payload).merge("schema" => ModelCorpusDiscovery::OBSERVATIONS_VERSION)
          conversations = payload.fetch("records").select { |record| record["kind"] == "conversations" }
          record = conversations.second
          document = payload.fetch("records").find { |item| item["kind"] == "document" }
          response["observations"] = [
            { "kind" => "diagnosis_vs_guess", "status" => "proposed", "summary" => "Reported signing symptom needs a diagnosis.",
              "uncertainty" => "The history does not establish a cause; expert review required.", "evidence" => [ record.slice("reference").merge("quote" => record.fetch("content")) ] },
            { "kind" => "escalation", "status" => "proposed", "summary" => "Shared playbook escalation needs review.",
              "uncertainty" => "Historic guidance may be wrong; expert review required.", "evidence" => [ document.slice("reference").merge("quote" => "Escalate repeated deletes with data loss to Engineering.") ] }
          ]
          if conversations.size < 20
            rare = conversations.last
            response["observations"] << { "kind" => "escalation", "status" => "proposed", "summary" => "A reported destructive retry meets the playbook's stated condition.",
              "uncertainty" => "These reports do not prove the right escalation or a resolution.", "evidence" => [ rare.slice("reference").merge("quote" => rare.fetch("content")), document.slice("reference").merge("quote" => "Escalate repeated deletes with data loss to Engineering.") ] }
          end
        end
        change&.call(response, payload)
        response.to_json
      end) { yield }
    end
  end
end
