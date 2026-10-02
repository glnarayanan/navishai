require_relative "http_target_test_helper"

module ModelDiscoveryTestHelper
  include HttpTargetTestHelper

  def build_discovery_corpus
    @workspace = workspaces(:acme_support)
    @membership = memberships(:owner_support)
    @corpus = @workspace.corpora.create!(name: "Synthetic technical-Support discovery")
    @records = [
      { id: "login", title: "Login stopped", content: "SSO stopped after signing certificate rotation. The engineer requested expiry evidence.", context: { idp: "Okta", plan: "enterprise" } },
      { id: "assertion", title: "Federation rejected", content: "Federation assertion rejected after trust bundle refresh. Tenant diagnostics show expired signing material." },
      { id: "rare", title: "Repeated delivery", content: "Webhook retries repeated a delete event and caused data loss. Customer remains blocked." }
    ]
    @snapshot = CorpusIntake.call(corpus: @corpus, membership: @membership, name: "History", kind: "conversations", bytes: @records.to_json)
    @items = @snapshot.corpus_items.index_by(&:external_id)
    @document = CorpusIntake.call(corpus: @corpus, membership: @membership, name: "Playbook", kind: "document",
      bytes: "Request the signing certificate expiry before changing SSO configuration. Escalate repeated deletes with data loss to Engineering.").corpus_items.sole
  end

  def discovery_configuration
    { "endpoint" => HTTP_ENDPOINT, "model" => "discovery-fixture-2026-10", "settings" => { "temperature" => 0, "max_output_tokens" => 4096, "seed" => 29 } }
  end

  def discovery_input
    ModelCorpusDiscovery.input(CorpusAnalysis.current_inputs(corpus: @corpus, model: true))
  end

  def request_model_analysis(**options)
    CorpusAnalysis.request!(**{ corpus: @corpus, membership: @membership, scenario_limit: 2, configuration: discovery_configuration,
      disclose: true, input_digest: ModelCorpusDiscovery.digest(discovery_input) }.merge(options))
  end

  def discovery_response
    login, assertion, rare, document = [ @items.fetch("login"), @items.fetch("assertion"), @items.fetch("rare"), @document ].map { |item| "corpus-item-#{item.id}" }
    { "schema" => "support-corpus-v1", "model" => "discovery-fixture-2026-10", "decision" => "proposal", "reason" => "Synthetic fixture: distinguish signing-material failures from dangerous delivery retries.",
      "clusters" => [
        { "label" => "Signing-material lifecycle", "reason" => "These different symptoms follow replacement of signing material.", "members" => [ login, assertion ], "possible_documentation_gap" => false,
          "evidence" => [ { "reference" => login, "quote" => "SSO stopped after signing certificate rotation." }, { "reference" => assertion, "quote" => "Federation assertion rejected after trust bundle refresh." } ] },
        { "label" => "Unsafe delete retries", "reason" => "A rare destructive retry needs attention despite low volume.", "members" => [ rare ], "possible_documentation_gap" => true,
          "evidence" => [ { "reference" => rare, "quote" => "Webhook retries repeated a delete event and caused data loss." } ] }
      ],
      "candidates" => [
        { "reference" => rare, "reason" => "Prioritise the rare destructive retry before another identity example.",
          "scenario" => { "title" => "Destructive webhook replay", "situation" => "A webhook retry repeats a delete while the customer remains blocked.", "taxonomy_label" => "Unsafe delete retries", "importance" => "critical", "known_facts" => {}, "hidden_facts" => {},
            "requirements" => ScenarioVersion::REQUIREMENT_TYPES.index_with { [] }.merge("outcomes" => [ "Escalate repeated destructive deletes to Engineering." ]) },
          "evidence_links" => [ { "kind" => "outcomes", "index" => 0, "reference" => document, "quote" => "Escalate repeated deletes with data loss to Engineering." } ] },
        { "reference" => login, "reason" => "Represent the shared signing-material family with a diagnostic case.",
          "scenario" => { "title" => "Signing-material diagnostics", "situation" => "Enterprise SSO stopped after the signing certificate changed.", "taxonomy_label" => "Signing-material lifecycle", "importance" => "high", "known_facts" => { "idp" => "Okta" }, "hidden_facts" => {},
            "requirements" => ScenarioVersion::REQUIREMENT_TYPES.index_with { [] }.merge("actions" => [ "Collect the signing certificate expiry before changing configuration." ]) },
          "evidence_links" => [ { "kind" => "actions", "index" => 0, "reference" => document, "quote" => "Request the signing certificate expiry before changing SSO configuration." } ] }
      ], "usage" => { "input_tokens" => 471, "output_tokens" => 319 }, "cost" => nil }
  end

  def with_corpus_approval
    original = ENV["NAVISHAI_CORPUS_ENDPOINTS"]
    ENV["NAVISHAI_CORPUS_ENDPOINTS"] = [ { workspace_id: @workspace.id, endpoint: HTTP_ENDPOINT, bearer_token: "test-only-corpus-token" } ].to_json
    yield
  ensure
    original ? ENV["NAVISHAI_CORPUS_ENDPOINTS"] = original : ENV.delete("NAVISHAI_CORPUS_ENDPOINTS")
  end

  def with_discovery_response(response: discovery_response, calls: [])
    with_corpus_approval do
      with_test_method(Resolv, :getaddresses, ->(*) { [ "93.184.216.34" ] }) do
        with_test_method(EvaluationHttp, :perform, ->(_uri, request, _address) { calls << request; response.to_json }) { yield }
      end
    end
  end
end
