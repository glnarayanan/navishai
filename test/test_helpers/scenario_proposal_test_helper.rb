require_relative "scenario_test_helper"
require_relative "http_target_test_helper"

module ScenarioProposalTestHelper
  include ScenarioTestHelper
  include HttpTargetTestHelper

  def build_proposal_scenario
    build_scenarios
    @scenario.revise!(membership: @membership, base_version_id: @scenario.current_version_id,
      attributes: { situation: "Enterprise SAML login stopped after a certificate change.", hidden_facts: { actual_cause: "private diagnosis" },
        requirements: ScenarioVersion::REQUIREMENT_TYPES.index_with { [] }.merge("outcomes" => [ "Expert-only prior expectation" ]) })
    @version = @scenario.reload.current_version
  end

  def proposal_configuration
    { "endpoint" => HTTP_ENDPOINT, "model" => "scenario-fixture-2026-10", "settings" => { "temperature" => 0, "max_output_tokens" => 2048, "seed" => 41 } }
  end

  def request_proposal(disclose: true, **options)
    ScenarioProposal.request!(version: @version, membership: @membership, configuration: proposal_configuration, disclose:, **options)
  end

  def proposal_response
    reference = "scenario-evidence-#{@version.scenario_evidence.find_by!(corpus_item: @scenario.corpus_item, kind: "expectation").id}"
    { "schema" => "source-scenario-v1", "model" => "scenario-fixture-2026-10", "decision" => "proposal", "reason" => "Synthetic fixture: diagnostics before configuration and an evidence-based Engineering handoff.",
      "scenario" => { "title" => "SAML certificate diagnostics", "situation" => "Enterprise SAML login stopped after a certificate change.", "taxonomy_label" => "SSO diagnostics", "importance" => "high", "known_facts" => { "idp" => "Okta" }, "hidden_facts" => {},
        "requirements" => { "outcomes" => [ "Escalate valid metadata with repeated ACS 500 to Engineering." ], "actions" => [ "Collect the certificate expiry date before changing configuration." ], "forbidden" => [], "escalation" => [], "grounding" => [] } },
      "evidence_links" => [ { "kind" => "outcomes", "index" => 0, "reference" => reference, "quote" => "Engineering escalation if valid metadata returns 500." },
        { "kind" => "actions", "index" => 0, "reference" => reference, "quote" => "Request the expiry date before changing configuration." } ],
      "usage" => { "input_tokens" => 327, "output_tokens" => 182 }, "cost" => nil }
  end

  def with_scenario_approval(workspace_id: @workspace.id, endpoint: HTTP_ENDPOINT)
    original = ENV["NAVISHAI_SCENARIO_ENDPOINTS"]
    ENV["NAVISHAI_SCENARIO_ENDPOINTS"] = [ { workspace_id:, endpoint:, bearer_token: "test-only-scenario-token" } ].to_json
    yield
  ensure
    original ? ENV["NAVISHAI_SCENARIO_ENDPOINTS"] = original : ENV.delete("NAVISHAI_SCENARIO_ENDPOINTS")
  end

  def with_proposal_response(response: proposal_response, calls: [])
    with_scenario_approval do
      with_test_method(Resolv, :getaddresses, ->(*) { [ "93.184.216.34" ] }) do
        with_test_method(EvaluationHttp, :perform, ->(_uri, request, _address) { calls << request; response.to_json }) { yield }
      end
    end
  end
end
