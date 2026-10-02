module FailureMatchingFixture
  def build_failure_matching_fixture
    @membership = memberships(:owner_support)
    @corpus = @membership.workspace.corpora.create!(name: "Failure matching fixture")
    traces = JSON.parse(File.read(Rails.root.join("test/fixtures/files/production_traces.json")))
    @item = CorpusIntake.call(corpus: @corpus, membership: @membership, name: "Failure traces", kind: "traces", bytes: traces.to_json).corpus_items.sole
    @document = CorpusIntake.call(corpus: @corpus, membership: @membership, name: "Certificate policy", kind: "document",
      bytes: "For certificate rotation failures, request expiry evidence before changing configuration. Invoices require a billing contact.").corpus_items.sole
    @version = matching_version
  end

  def matching_version(title: "Certificate rotation diagnostics", situation: "After certificate rotation, authentication fails. Request expiry evidence.", facts: { "plan" => "business", "idp" => "Okta" }, corpus: @corpus, item: @document, excerpt: "For certificate rotation failures, request expiry evidence before changing configuration.")
    scenario = corpus.scenarios.create!(workspace: corpus.workspace, corpus_item: item)
    version = scenario.scenario_versions.create!(workspace: corpus.workspace, corpus:, created_by: @membership.user,
      number: 1, origin: "expert", title:, situation:, taxonomy_label: title, importance: "normal", known_facts: facts,
      hidden_facts: {}, requirements: ScenarioVersion::REQUIREMENT_TYPES.index_with { [] }, selection_reason: "Fixture expert proposal", created_at: Time.current)
    version.scenario_evidence.create!(workspace: corpus.workspace, corpus:, corpus_item: item, kind: "expectation", excerpt:)
    scenario.update!(current_version: version)
    version
  end

  def append_decision(version: @version, membership: @membership, decision: "match", reason: "Same certificate failure; entitlement differs.")
    TraceScenarioDecision.append!(item: @item, version:, membership:, decision:, reason:)
  end
end
