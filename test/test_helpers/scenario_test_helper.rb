module ScenarioTestHelper
  def build_scenarios
    @membership = memberships(:owner_support)
    @workspace = @membership.workspace
    @corpus = @workspace.corpora.create!(name: "Technical history")
    @snapshot = CorpusIntake.call(corpus: @corpus, membership: @membership, name: "Support export", kind: "conversations", bytes: [
      { id: "sso", title: "SSO stopped after certificate rotation", content: "Customer cannot sign in after certificate rotation. Request the expiry date before changing configuration. Engineering escalation if valid metadata returns 500.", context: { plan: "enterprise", idp: "Okta" } },
      { id: "api", title: "Webhook replay loses records", content: "A webhook replay caused data loss. Collect request IDs and escalate to Engineering. Do not close until replay integrity is verified.", context: { impact: "critical" } }
    ].to_json)
    @knowledge = CorpusIntake.call(corpus: @corpus, membership: @membership, name: "SSO playbook", kind: "document", bytes: "Request the certificate expiry date. Escalate valid metadata with ACS 500 to Engineering.").corpus_items.sole
    @analysis = CorpusAnalysis.request!(corpus: @corpus, membership: @membership, scenario_limit: 2)
    CorpusAnalysisJob.perform_now(@analysis.id)
    @scenarios = ScenarioMining.call(analysis: @analysis, membership: @membership)
    @scenario = @scenarios.find { |scenario| scenario.corpus_item.external_id == "sso" }
  end

  def approve_scenario(scenario = @scenario)
    requirements = ScenarioVersion::REQUIREMENT_TYPES.index_with { [] }.merge("outcomes" => [ "Identify certificate expiry as a possible cause." ], "actions" => [ "Request the certificate expiry date." ])
    scenario.revise!(membership: @membership, base_version_id: scenario.current_version_id, attributes: { situation: "SSO stopped after a customer changed the certificate.", requirements: })
    scenario.review!(membership: @membership, version_id: scenario.current_version_id, decision: "approve", note: "Checked against our playbook.")
    scenario.reload
  end
end
