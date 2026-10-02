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
end
