require_relative "scenario_test_helper"
require_relative "http_target_test_helper"

module AssumptionImpactTestHelper
  include ScenarioTestHelper
  include HttpTargetTestHelper

  def build_change_impact
    build_scenarios
    requirements = ScenarioVersion::REQUIREMENT_TYPES.index_with { [] }.merge("outcomes" => [ "Treat Business SAML as unsupported." ])
    @version = @scenario.revise!(membership: @membership, base_version_id: @scenario.current_version_id,
      attributes: { situation: "A Business plan customer needs SAML login.", known_facts: { plan: "business", retries: 0.0 },
        hidden_facts: { assumption: "Business excludes SAML" }, requirements: })
    @scenario.review!(membership: @membership, version_id: @version.id, decision: "approve", note: "Synthetic expert fixture only.")
    @before = import_impact_document("Only Enterprise plans support SAML. Business customers use password login.")
    @after = import_impact_document("Business and Enterprise plans support SAML. Existing Business customers can configure SAML.")
    @source = @after.source
    @version_ids = @scenarios.map { |scenario| scenario.reload.current_version_id }.sort
  end

  def import_impact_document(text)
    CorpusIntake.call(corpus: @corpus, membership: @membership, name: "Product entitlement", kind: "document", bytes: text)
  end

  def impact_configuration
    { "endpoint" => HTTP_ENDPOINT, "model" => "change-fixture-2026-10", "settings" => { "temperature" => 0, "max_output_tokens" => 2048, "seed" => 17 } }
  end

  def impact_preview(**overrides)
    AssumptionChangeAnalysis.preview(**{ corpus: @corpus, source_id: @source.id, before_snapshot_id: @before.id, after_snapshot_id: @after.id, version_ids: @version_ids }.merge(overrides))
  end

  def request_impact(**overrides)
    attributes = { corpus: @corpus, membership: @membership, source_id: @source.id,
      before_snapshot_id: @before.id, after_snapshot_id: @after.id, version_ids: @version_ids,
      configuration: impact_configuration, input_digest: AssumptionChangeAnalysis.digest(impact_preview), disclose: true }.merge(overrides)
    attributes[:wire_digest] = overrides.fetch(:wire_digest) { AssumptionChangeAnalysis.wire_digest(impact_preview, attributes.fetch(:configuration)) }
    AssumptionImpact.request!(**attributes)
  end

  def impact_response
    { "schema" => "source-assumption-impact-v2", "model" => "change-fixture-2026-10", "decision" => "proposal",
      "reason" => "Synthetic fixture: changed SAML entitlement may affect this scenario.",
      "affected" => [ { "reference" => "scenario-version-#{@version.id}", "field" => "requirements", "assumption_quote" => "Treat Business SAML as unsupported.",
        "before_quote" => "Only Enterprise plans support SAML.", "after_quote" => "Business and Enterprise plans support SAML.",
        "reason" => "The scenario expects an unsupported-plan outcome but the document now includes Business.",
        "uncertainty" => "An expert must check rollout dates and account exceptions; the quotes do not prove this customer's entitlement." } ],
      "usage" => { "input_tokens" => 601, "output_tokens" => 129 }, "cost" => nil }
  end

  def with_impact_approval(workspace_id: @workspace.id, endpoint: HTTP_ENDPOINT)
    original = ENV["NAVISHAI_IMPACT_ENDPOINTS"]
    ENV["NAVISHAI_IMPACT_ENDPOINTS"] = [ { workspace_id:, endpoint:, bearer_token: "test-only-impact-token" } ].to_json
    yield
  ensure
    original ? ENV["NAVISHAI_IMPACT_ENDPOINTS"] = original : ENV.delete("NAVISHAI_IMPACT_ENDPOINTS")
  end

  def with_impact_response(response: impact_response, calls: [], during_call: nil)
    with_impact_approval do
      with_test_method(Resolv, :getaddresses, ->(*) { [ "93.184.216.34" ] }) do
        with_test_method(EvaluationHttp, :perform, ->(_uri, request, _address) { calls << request; during_call&.call; response.to_json }) { yield }
      end
    end
  end

  def with_old_purpose_approvals
    registries = %w[NAVISHAI_CORPUS_ENDPOINTS NAVISHAI_SCENARIO_ENDPOINTS NAVISHAI_EVALUATION_ENDPOINTS NAVISHAI_MATCHING_ENDPOINTS NAVISHAI_IMPACT_ENDPOINTS]
    originals = registries.index_with { |key| ENV[key] }
    registries.each { |key| ENV[key] = [ { workspace_id: @workspace.id, endpoint: HTTP_ENDPOINT, bearer_token: "old-purpose-token" } ].to_json }
    ENV.delete("NAVISHAI_IMPACT_ENDPOINTS")
    yield
  ensure
    originals.each { |key, value| value ? ENV[key] = value : ENV.delete(key) }
  end

  def impact_selection_params
    { source_id: @source.id, before_snapshot_id: @before.id, after_snapshot_id: @after.id, scenario_ids: @scenarios.map(&:id).join(" ") }
  end

  def impact_request_params
    impact_selection_params.except(:scenario_ids).merge(version_ids: @version_ids.join(" "),
      input_digest: AssumptionChangeAnalysis.digest(impact_preview),
      wire_digest: AssumptionChangeAnalysis.wire_digest(impact_preview, impact_configuration),
      configuration: impact_configuration.to_json, impact_disclose: "1")
  end
end
