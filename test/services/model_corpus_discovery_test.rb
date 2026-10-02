require "test_helper"
require_relative "../test_helpers/model_discovery_test_helper"

class ModelCorpusDiscoveryTest < ActiveSupport::TestCase
  include ModelDiscoveryTestHelper
  setup { build_discovery_corpus }

  test "fixed model discovery retains company families and rare source-backed scenarios without approval" do
    calls = []
    with_discovery_response(calls:) do
      @analysis = request_model_analysis
      2.times { CorpusAnalysisJob.perform_now(@analysis.id) }
    end
    assert_equal "complete", @analysis.reload.state
    assert_equal({ "conversations" => 3, "documents" => 1, "clusters" => 2, "selected" => 2, "represented_clusters" => 2 }, @analysis.summary)
    assert_equal 1, calls.size
    payload = JSON.parse(calls.sole.body)
    assert_equal %w[candidate_limit instructions model records schema settings], payload.keys.sort
    assert_equal 2, payload["candidate_limit"]
    assert_equal "support-corpus-v1", payload["schema"]
    assert_equal [ "History", "Playbook" ], @analysis.corpus_items.joins(source_snapshot: :source).distinct.pluck("sources.name").sort
    assert_equal @analysis.request_key, calls.sole["Idempotency-Key"]
    assert_equal [ "assertion", "login" ], @analysis.issue_clusters.find_by!(proposed_label: "Signing-material lifecycle").cluster_members.map { |member| member.corpus_item.external_id }.sort
    assert_equal 0, Scenario.count
    cluster = @analysis.issue_clusters.find_by!(proposed_label: "Signing-material lifecycle")
    TaxonomyVersion.review!(analysis: @analysis, membership: @membership, cluster_id: cluster.id, label: "Expert's identity family")
    scenarios = ScenarioMining.call(analysis: @analysis, membership: @membership)
    assert_equal 2, scenarios.size
    rare = scenarios.find { |scenario| scenario.corpus_item.external_id == "rare" }.current_version
    assert_equal "Destructive webhook replay", rare.title
    assert_equal "critical", rare.importance
    assert_equal [ "Escalate repeated destructive deletes to Engineering." ], rare.requirements["outcomes"]
    assert_equal [ "Escalate repeated deletes with data loss to Engineering.", "Webhook retries repeated a delete event and caused data loss." ], rare.scenario_evidence.pluck(:excerpt).sort
    assert_equal 0, rare.scenario_evidence.where(kind: "knowledge").count
    assert_not rare.approved?
    identity = scenarios.find { |scenario| scenario.corpus_item.external_id == "login" }.current_version
    assert_equal "Expert's identity family", identity.taxonomy_label
    assert_equal "Enterprise SSO stopped after the signing certificate changed.", identity.situation
    assert_raises(Scenario::Invalid) { identity.scenario.review!(membership: @membership, version_id: identity.id, decision: "approve") }
    assert_no_difference([ "Scenario.count", "ScenarioVersion.count", "ScenarioEvidence.count" ]) { ScenarioMining.call(analysis: @analysis, membership: @membership) }
    assert_equal 0, HumanLabel.count
    assert_nil @analysis.corpus_analysis_result.result["cost"]
  end

  test "malformed partitions candidate schemas and invented or foreign quotes save no partial proposal" do
    with_corpus_approval { @analysis = request_model_analysis }
    invalid_changes = [
      ->(value) { value["clusters"][0]["members"].pop },
      ->(value) { value["clusters"][1]["members"][0] = value["clusters"][0]["members"][0] },
      ->(value) { value["clusters"][0]["evidence"][0]["quote"] = "Invented diagnosis" },
      ->(value) { value["candidates"][0]["evidence_links"][0]["reference"] = "corpus-item-999999999" },
      ->(value) { value["candidates"][0]["evidence_links"] = [] },
      ->(value) { value["candidates"][0]["scenario"]["title"] = 123 },
      ->(value) { value["candidates"][0]["scenario"]["taxonomy_label"] = "Unrelated family" },
      ->(value) { value["candidates"][1] = value["candidates"][0].deep_dup },
      ->(value) { value["model"] = "different-model" },
      ->(value) { value["cost"] = { "currency" => "USD", "micro_units" => -1 } },
      ->(value) { value["claimed_coverage"] = 100 }
    ]
    invalid_changes.each do |change|
      response = discovery_response.deep_dup
      change.call(response)
      assert_raises(SupportOutput::Invalid) { ModelCorpusDiscovery.validate_response!(response, analysis: @analysis, input: discovery_input) }
    end
    with_discovery_response(response: discovery_response.merge("clusters" => [])) { 2.times { CorpusAnalysisJob.perform_now(@analysis.id) } }
    assert_equal "error", @analysis.reload.corpus_analysis_result.result["decision"]
    assert_empty @analysis.issue_clusters
    assert_equal 0, @analysis.summary["selected"]
  end

  test "a valid abstention creates no scenarios or clusters and never supplies truth" do
    response = discovery_response.merge("decision" => "abstain", "reason" => "Synthetic fixture: evidence is too sparse.", "clusters" => [], "candidates" => [], "usage" => nil)
    with_discovery_response(response:) do
      analysis = request_model_analysis
      CorpusAnalysisJob.perform_now(analysis.id)
      assert_equal "abstain", analysis.reload.corpus_analysis_result.result["decision"]
      assert_empty ScenarioMining.call(analysis:, membership: @membership)
    end
    assert_equal 0, TaxonomyVersion.count
    assert_equal 0, ScenarioReview.count
  end

  test "requirement quotes share one exact source window without losing evidence" do
    policy = "Préface. First diagnostic. Evidence between. Final escalation."
    current = CorpusIntake.call(corpus: @corpus, membership: @membership, name: "Window", kind: "document", bytes: policy).corpus_items.sole
    reference = "corpus-item-#{current.id}"
    response = discovery_response
    candidate = response["candidates"][0]
    candidate["scenario"]["requirements"]["outcomes"] = [ "Diagnose first.", "Escalate last." ]
    candidate["evidence_links"] = [ { "kind" => "outcomes", "index" => 0, "reference" => reference, "quote" => "First diagnostic." }, { "kind" => "outcomes", "index" => 1, "reference" => reference, "quote" => "Final escalation." } ]
    with_discovery_response(response:) do
      analysis = request_model_analysis
      CorpusAnalysisJob.perform_now(analysis.id)
      rare = ScenarioMining.call(analysis:, membership: @membership).find { |scenario| scenario.corpus_item.external_id == "rare" }
      assert_equal "First diagnostic. Evidence between. Final escalation.", rare.current_version.scenario_evidence.find_by!(corpus_item: current).excerpt
    end
    far = "First diagnostic." + "x" * 4000 + "Final escalation."
    next_item = CorpusIntake.call(corpus: @corpus, membership: @membership, name: "Window", kind: "document", bytes: far).corpus_items.sole
    candidate["evidence_links"].each { |link| link["reference"] = "corpus-item-#{next_item.id}" }
    with_corpus_approval do
      analysis = request_model_analysis
      assert_raises(SupportOutput::Invalid) { ModelCorpusDiscovery.validate_response!(response, analysis:, input: discovery_input) }
    end
  end

  test "v2 retains all uncertain support observations and exact cross-source quotes without expert decisions" do
    analysis = build_observation_analysis
    expected = observation_response
    calls = []
    with_discovery_response(response: expected, calls:) do
      response = ModelCorpusDiscovery.call(analysis, input: discovery_input)
      assert_equal expected.fetch("observations"), response.fetch("observations")
      analysis.corpus.with_lock { ModelCorpusDiscovery.persist!(analysis, response) }
    end
    assert_equal 1, calls.size
    payload = JSON.parse(calls.sole.body)
    assert_equal "support-corpus-v2", payload.fetch("schema")
    assert_equal discovery_input.fetch("records"), payload.fetch("records")
    assert_equal analysis.request_key, calls.sole["Idempotency-Key"]
    assert_includes payload.fetch("instructions"), "competing interpretations"
    retained = analysis.reload.corpus_analysis_result.result.fetch("observations")
    assert_equal expected.fetch("observations"), retained
    assert_equal %w[contradictory_guidance agent_disagreement false_resolution reopen policy_exception diagnosis_vs_guess escalation customer_variant], retained.pluck("kind")
    assert retained.all? { |observation| observation["status"] == "proposed" && observation["uncertainty"].present? }
    assert_equal 2, retained.first.fetch("evidence").pluck("reference").uniq.size
    assert_equal 0, TaxonomyVersion.count
    assert_equal 0, HumanLabel.count
    assert_equal 0, Scenario.count
    assert_raises(ActiveRecord::StatementInvalid) do
      CorpusAnalysisResult.transaction(requires_new: true) { CorpusAnalysisResult.where(id: analysis.corpus_analysis_result.id).update_all(result: expected.merge("observations" => [])) }
    end
  end

  test "v1 and v2 reject each other's schemas and do not reinterpret historical results" do
    analysis = build_observation_analysis
    assert_raises(SupportOutput::Invalid) { ModelCorpusDiscovery.validate_response!(discovery_response, analysis:, input: discovery_input) }
    assert_raises(SupportOutput::Invalid) { ModelCorpusDiscovery.validate_response!(observation_response.except("observations"), analysis:, input: discovery_input) }
    legacy = build_observation_analysis(version: ModelCorpusDiscovery::VERSION)
    assert_equal discovery_response, ModelCorpusDiscovery.validate_response!(discovery_response, analysis: legacy, input: discovery_input)
    assert_raises(SupportOutput::Invalid) { ModelCorpusDiscovery.validate_response!(observation_response, analysis: legacy, input: discovery_input) }
    assert_raises(SupportOutput::Invalid) { ModelCorpusDiscovery.validate_response!(discovery_response.merge("observations" => []), analysis: legacy, input: discovery_input) }
    unsupported = Struct.new(:processing_method).new("support-corpus-v999")
    assert_raises(CorpusIntake::Invalid) { ModelCorpusDiscovery.protocol_for(unsupported) }
  end

  test "every observation and evidence member rejects malformed foreign invented and unsupported findings" do
    analysis = build_observation_analysis
    mutations = [
      ->(value) { value["kind"] = "sentiment_score" },
      ->(value) { value["status"] = "verified" },
      ->(value) { value.delete("uncertainty") },
      ->(value) { value["uncertainty"] = " " },
      ->(value) { value["summary"] = 12 },
      ->(value) { value["summary"] = "" },
      ->(value) { value["summary"] += "\u0000" },
      ->(value) { value["accuracy"] = 1 },
      ->(value) { value["evidence"] = nil },
      ->(value) { value["evidence"] = [] },
      ->(value) { value["evidence"] = value["evidence"].first(1) },
      ->(value) { value["evidence"] = [ value["evidence"].first ] * 2 }
    ]
    [ 0, 3, 7 ].each do |position|
      mutations.each do |mutation|
        response = observation_response
        mutation.call(response.fetch("observations")[position])
        assert_raises(SupportOutput::Invalid) { ModelCorpusDiscovery.validate_response!(response, analysis:, input: discovery_input) }
      end
      response = observation_response
      response["observations"][position] = nil
      assert_raises(SupportOutput::Invalid) { ModelCorpusDiscovery.validate_response!(response, analysis:, input: discovery_input) }
    end
    evidence_mutations = [
      ->(quote) { quote["reference"] = "corpus-item-999999999" },
      ->(quote) { quote["reference"] = [ quote["reference"] ] },
      ->(quote) { quote["quote"] = "Invented guidance." },
      ->(quote) { quote["quote"] = " " },
      ->(quote) { quote["quote"] = nil },
      ->(quote) { quote["reference"] = "corpus-item-#{quote['reference'] == "corpus-item-#{@macro.id}" ? @document.id : @macro.id}" },
      ->(quote) { quote["position"] = 0 }
    ]
    [ 0, 1 ].each do |position|
      evidence_mutations.each do |mutation|
        response = observation_response
        mutation.call(response["observations"].first.fetch("evidence")[position])
        assert_raises(SupportOutput::Invalid) { ModelCorpusDiscovery.validate_response!(response, analysis:, input: discovery_input) }
      end
    end
    [ nil, {}, "findings", [ false ] ].each do |observations|
      assert_raises(SupportOutput::Invalid) { ModelCorpusDiscovery.validate_response!(observation_response.merge("observations" => observations), analysis:, input: discovery_input) }
    end
  end

  test "observation array evidence and exact Unicode text boundaries reject rather than truncate" do
    analysis = build_observation_analysis
    input = discovery_input
    text = "é" * 2001
    reference = input.fetch("records").first.fetch("reference")
    input.fetch("records").first["content"] += text
    observation = observation_response.fetch("observations")[4].merge("evidence" => [ { "reference" => reference, "quote" => text[0, 2000] } ])
    response = observation_response.merge("observations" => [ observation.merge("summary" => text[0, 2000], "uncertainty" => text[0, 2000]) ])
    assert_equal response, ModelCorpusDiscovery.validate_response!(response, analysis:, input:)
    %w[summary uncertainty].each do |field|
      [ text, "x" + " " * 2000 ].each do |value|
        invalid = response.deep_dup
        invalid["observations"].sole[field] = value
        assert_raises(SupportOutput::Invalid) { ModelCorpusDiscovery.validate_response!(invalid, analysis:, input:) }
      end
    end
    invalid = response.deep_dup
    invalid["observations"].sole["evidence"].sole["quote"] = text
    assert_raises(SupportOutput::Invalid) { ModelCorpusDiscovery.validate_response!(invalid, analysis:, input:) }
    response["observations"] = 100.times.map { |index| observation.merge("summary" => "Fixture observation #{index}") }
    assert_equal 100, ModelCorpusDiscovery.validate_response!(response, analysis:, input:).fetch("observations").size
    response["observations"] << observation
    assert_raises(SupportOutput::Invalid) { ModelCorpusDiscovery.validate_response!(response, analysis:, input:) }
    response["observations"] = [ observation.merge("evidence" => 8.times.map { |index| { "reference" => reference, "quote" => "é" * (index + 1) } }) ]
    assert_equal response, ModelCorpusDiscovery.validate_response!(response, analysis:, input:)
    response["observations"].sole["evidence"] << { "reference" => reference, "quote" => "é" * 9 }
    assert_raises(SupportOutput::Invalid) { ModelCorpusDiscovery.validate_response!(response, analysis:, input:) }
  end

  test "empty observations stay honest and abstention cannot retain a partial finding" do
    analysis = build_observation_analysis
    empty = observation_response.merge("observations" => [])
    assert_equal empty, ModelCorpusDiscovery.validate_response!(empty, analysis:, input: discovery_input)
    abstain = empty.merge("decision" => "abstain", "clusters" => [], "candidates" => [])
    assert_equal abstain, ModelCorpusDiscovery.validate_response!(abstain, analysis:, input: discovery_input)
    assert_raises(SupportOutput::Invalid) { ModelCorpusDiscovery.validate_response!(abstain.merge("observations" => observation_response.fetch("observations")), analysis:, input: discovery_input) }
    calls = []
    malformed = observation_response
    malformed.fetch("observations").last.fetch("evidence").last["quote"] = "Invented late finding"
    with_discovery_response(response: malformed, calls:) do
      response = ModelCorpusDiscovery.call(analysis, input: discovery_input)
      assert_equal "error", response.fetch("decision")
      analysis.corpus.with_lock { ModelCorpusDiscovery.persist!(analysis, response) }
    end
    assert_equal 1, calls.size
    assert_empty analysis.issue_clusters
    assert_nil analysis.corpus_analysis_result.result["observations"]
    assert_equal 0, Scenario.count
  end

  private

  def build_observation_analysis(version: ModelCorpusDiscovery::OBSERVATIONS_VERSION)
    records = @records.deep_dup
    records[0][:content] += " Agent Ada: Likely expired; no logs yet. Agent Ben: Expiry is valid; collect assertion audience. Agent Ada marked resolved. Customer reopened: sign-in still fails. Enterprise tenants use an IdP certificate."
    records[1][:content] += " Business tenants use a service certificate."
    records[2][:content] += " Manager allowed replay only for account 17, despite default prohibition."
    @snapshot = CorpusIntake.call(corpus: @corpus, membership: @membership, name: "History", kind: "conversations", bytes: records.to_json)
    @items = @snapshot.corpus_items.index_by(&:external_id)
    @macro = CorpusIntake.call(corpus: @corpus, membership: @membership, name: "Legacy macro", kind: "document", bytes: "Rotate the certificate before collecting expiry.").corpus_items.sole
    analysis = @corpus.corpus_analyses.create!(workspace: @workspace, requested_by: @membership.user, processing_method: version,
      scenario_limit: 2, configuration: discovery_configuration, input_digest: ModelCorpusDiscovery.digest(discovery_input))
    @corpus.current_items.pluck(:id).each { |id| analysis.corpus_analysis_inputs.create!(workspace: @workspace, corpus: @corpus, corpus_item_id: id) }
    analysis
  end

  def observation_response
    login, assertion, rare, document, macro = [ @items.fetch("login"), @items.fetch("assertion"), @items.fetch("rare"), @document, @macro ].map { |item| "corpus-item-#{item.id}" }
    observations = [
      [ "contradictory_guidance", "Macro puts rotation before evidence; the playbook puts evidence first.", [ [ macro, "Rotate the certificate before collecting expiry." ], [ document, "Request the signing certificate expiry before changing SSO configuration." ] ] ],
      [ "agent_disagreement", "Agents report different expiry states.", [ [ login, "Agent Ada: Likely expired; no logs yet." ], [ login, "Agent Ben: Expiry is valid; collect assertion audience." ] ] ],
      [ "false_resolution", "Closure precedes a reported continuing failure.", [ [ login, "Agent Ada marked resolved." ], [ login, "Customer reopened: sign-in still fails." ] ] ],
      [ "reopen", "The customer reports a reopen after closure.", [ [ login, "Agent Ada marked resolved." ], [ login, "Customer reopened: sign-in still fails." ] ] ],
      [ "policy_exception", "A manager reports a narrow replay exception.", [ [ rare, "Manager allowed replay only for account 17, despite default prohibition." ] ] ],
      [ "diagnosis_vs_guess", "The first expiry claim is tentative and reports no logs.", [ [ login, "Agent Ada: Likely expired; no logs yet." ] ] ],
      [ "escalation", "The playbook names a data-loss escalation condition.", [ [ document, "Escalate repeated deletes with data loss to Engineering." ] ] ],
      [ "customer_variant", "Reported certificate types differ across plans.", [ [ login, "Enterprise tenants use an IdP certificate." ], [ assertion, "Business tenants use a service certificate." ] ] ]
    ].map do |kind, summary, evidence|
      { "kind" => kind, "status" => "proposed", "summary" => summary, "uncertainty" => "Authored fixture reports only; experts must check context and correctness.",
        "evidence" => evidence.map { |reference, quote| { "reference" => reference, "quote" => quote } } }
    end
    discovery_response.merge("schema" => ModelCorpusDiscovery::OBSERVATIONS_VERSION, "observations" => observations)
  end
end
