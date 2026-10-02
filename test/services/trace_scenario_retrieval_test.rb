require "test_helper"

# Independently authored synthetic situations, not customer labels or approvals.
# Intended identities express the author's causal reading; literal ranks are a
# separate, explicit oracle. No matcher tokenization/scoring is used by helpers.
class TraceScenarioRetrievalTest < ActiveSupport::TestCase
  setup do
    @membership = memberships(:owner_support)
    @corpus = @membership.workspace.corpora.create!(name: "Authored retrieval matrix")
    @versions = {}
  end

  test "issue diagnosis loses to a verbose symptom despite being retrieved" do
    scenario(:cause, "Signing key drift", "Identity metadata retains an obsolete signing key.",
      excerpt: "Inspect certificate rotation before refreshing metadata.")
    scenario(:symptom, "Login failure", "Login failure after certificate rotation blocks dashboard access.",
      excerpt: "Record the login failure and dashboard access symptom.")
    trace = intake_trace("Login failure after certificate rotation blocks dashboard access.", "Diagnosis omitted.")

    assert_retrieval(trace, intended: :cause, ranked: [ :symptom, :cause ], intended_rank: 2,
      shared: [ %w[access after blocks certificate dashboard failure login rotation], %w[certificate rotation] ])
  end

  test "same vocabulary different cause favors equal facts not diagnostic compatibility" do
    scenario(:expired, "Expired credential", "Webhook delivery fails because the credential expired.", facts: { "region" => "west" })
    scenario(:firewall, "Firewall rule", "Webhook delivery fails because the firewall denies traffic.", facts: { "region" => "east" })
    trace = intake_trace("Webhook delivery fails.", "Credential expired.", facts: { "region" => "east" })

    # More literal terms outrank equal facts; the firewall still qualifies.
    result = assert_retrieval(trace, intended: :expired, ranked: [ :expired, :firewall ], intended_rank: 1,
      shared: [ %w[credential delivery expired fails webhook], %w[delivery fails webhook] ])
    assert_equal({ "trace" => "east", "scenario" => "west" }, result.candidates.first.conflicting_facts.fetch("region"))
    assert_equal({ "region" => "east" }, result.candidates.last.equal_facts)

    ambiguous = intake_trace("Webhook delivery fails.", "Diagnosis omitted.", facts: { "region" => "east" })
    assert_retrieval(ambiguous, intended: :expired, ranked: [ :firewall, :expired ], intended_rank: 2,
      shared: [ %w[delivery fails webhook], %w[delivery fails webhook] ])
  end

  test "negated diagnosis ties its opposite and older version wins" do
    scenario(:expired, "Certificate expiry", "Certificate expired.")
    scenario(:valid, "Certificate validity", "Certificate not expired.")
    trace = intake_trace("Certificate not expired.", "Incorrect diagnosis.")

    assert_retrieval(trace, intended: :valid, ranked: [ :expired, :valid ], intended_rank: 2,
      shared: [ %w[certificate expired], %w[certificate expired] ])
  end

  test "matching account facts alone cannot retrieve the intended issue" do
    scenario(:entitlement, "Enterprise Okta export entitlement", "Export denied until entitlement is enabled.",
      facts: { "plan" => "enterprise", "idp" => "Okta" })
    trace = intake_trace("Enterprise Okta account cannot download records.", "Agent guessed.",
      facts: { "plan" => "enterprise", "idp" => "Okta" })

    assert_retrieval(trace, intended: :entitlement, ranked: [], intended_rank: nil, shared: [])
  end

  test "five verbose unrelated causes displace a literal eligible diagnosis" do
    scenario(:cursor, "Cursor persistence", "Pagination cursor was discarded.")
    {
      permission: "Permission scope excludes archived records.",
      replica: "Replica lag hides recent records.",
      filter: "Date filter excludes archived records.",
      retention: "Retention policy deleted archived records.",
      cache: "Cache contains an obsolete response."
    }.each do |key, cause|
      scenario(key, "Export report", "Export pagination cursor skips archived records. #{cause}")
    end
    trace = intake_trace("Export pagination cursor skips archived records.", "Agent guessed.")

    assert_retrieval(trace, intended: :cursor, ranked: %i[permission replica filter retention cache], intended_rank: nil,
      shared: Array.new(5) { %w[archived cursor export pagination records skips] })
    # Establish eligibility independently with the same trace and a reduced pool,
    # through normal scenario revision, rather than changing the matcher limit.
    %i[permission replica filter retention cache].each do |key|
      version = @versions.fetch(key)
      version.scenario.revise!(membership: @membership, base_version_id: version.id,
        attributes: { title: "Unrelated billing", taxonomy_label: "Billing", situation: "Invoice reconciliation." })
    end
    assert_retrieval(trace, intended: :cursor, ranked: [ :cursor ], intended_rank: 1,
      shared: [ %w[cursor pagination] ])
  end

  test "zero overlap paraphrase misses a causally equivalent situation" do
    scenario(:throttle, "Rate limit", "Request quota exhausted; retry after cooldown.")
    trace = intake_trace("Traffic ceiling reached; wait before resending.", "Agent guessed.")

    assert_retrieval(trace, intended: :throttle, ranked: [], intended_rank: nil, shared: [])
  end

  test "expectation documents can introduce irrelevant vocabulary but trace and knowledge quotes cannot" do
    scenario(:dns, "Hostname resolution", "Resolver returns an obsolete address.", excerpt: "Inspect webhook timeout diagnostics.")
    scenario(:billing, "Invoice reconciliation", "Ledger balance differs.", excerpt: "Webhook timeout diagnostics also appear in this unrelated appendix.")
    ignored = scenario(:ignored, "Seat allocation", "Seat allocation denied.")
    contamination = intake_trace("Seat allocation denied.", "Agent guessed.",
      correction: "Webhook timeout diagnostics", output: "Webhook timeout diagnostics")
    ignored = ignored.scenario.revise!(membership: @membership, base_version_id: ignored.id,
      attributes: {}, evidence_item_id: contamination.id, excerpt: "Webhook timeout diagnostics", evidence_kind: "expectation")
    knowledge = CorpusIntake.call(corpus: @corpus, membership: @membership, name: "Permitted appendix", kind: "document",
      bytes: "Webhook timeout diagnostics").corpus_items.sole
    ignored = ignored.scenario.revise!(membership: @membership, base_version_id: ignored.id,
      attributes: {}, evidence_item_id: knowledge.id, excerpt: knowledge.content, evidence_kind: "knowledge")
    @versions[:ignored] = ignored
    trace = intake_trace("Webhook timeout.", "Diagnostics omitted.", correction: "Seat allocation denied.", output: "Seat allocation denied.")

    result = assert_retrieval(trace, intended: :dns, ranked: [ :dns, :billing ], intended_rank: 1,
      shared: [ %w[diagnostics timeout webhook], %w[diagnostics timeout webhook] ])
    assert_equal [ "document", "document" ], result.candidates.map { |candidate| candidate.evidence.sole.corpus_item.source_snapshot.source.kind }
    assert_equal 4, ignored.scenario_evidence.count
    assert_empty ignored.scenario_reviews
  end

  private
    def scenario(key, title, situation, facts: {}, excerpt: "Retain diagnostic provenance.")
      seed = intake_trace(situation, "Authored failure report.", facts:)
      draft = SupportTrace.propose!(item: seed, membership: @membership).current_version
      document = CorpusIntake.call(corpus: @corpus, membership: @membership, name: "Authored evidence #{key}",
        kind: "document", bytes: excerpt).corpus_items.sole
      @versions[key] = draft.scenario.revise!(membership: @membership, base_version_id: draft.id,
        attributes: { title:, situation:, taxonomy_label: "Technical support" },
        evidence_item_id: document.id, excerpt:, evidence_kind: "expectation")
    end

    def intake_trace(situation, failure, facts: {}, correction: "", output: "Diagnosis omitted.")
      id = "authored-#{@corpus.corpus_items.count}"
      record = { schema: "support-trace-v1", id:, title: "Authored trace #{id}", target_version: "synthetic-v1",
        observed_at: "2026-09-30T12:00:00Z", input: { situation:, known_facts: facts, knowledge: [] },
        observed_failure: failure, human_correction: correction,
        output: { messages: [ { role: "assistant", content: output } ], tool_calls: [], collected_fields: {},
          citations: [], escalation: { triggered: false, team: nil }, policy_branch: nil } }
      CorpusIntake.call(corpus: @corpus, membership: @membership, name: "Authored trace #{id}", kind: "traces",
        bytes: [ record ].to_json).corpus_items.sole
    end

    def assert_retrieval(trace, intended:, ranked:, intended_rank:, shared:)
      expected_ids = ranked.map { |key| @versions.fetch(key).id }
      intended_id = @versions.fetch(intended).id
      result = nil
      assert_no_difference [ "TraceScenarioDecision.count", "ScenarioReview.count", "AuditEvent.count" ] do
        result = TraceScenarioMatching.call(item: trace)
      end
      assert_nil result.message
      assert_equal @versions.size, result.searched_versions
      actual_ids = result.candidates.map { |candidate| candidate.version.id }
      assert_equal expected_ids, actual_ids
      actual_rank = actual_ids.index(intended_id)&.+(1)
      intended_rank.nil? ? assert_nil(actual_rank) : assert_equal(intended_rank, actual_rank)
      assert_equal shared, result.candidates.map(&:shared_terms)
      result
    end
end
