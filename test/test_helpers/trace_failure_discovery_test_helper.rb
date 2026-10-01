require_relative "model_discovery_test_helper"

module TraceFailureDiscoveryTestHelper
  include ModelDiscoveryTestHelper

  def build_trace_discovery
    @workspace = workspaces(:acme_support)
    @membership = memberships(:owner_support)
    @corpus = @workspace.corpora.create!(name: "Synthetic production discovery")
    original = JSON.parse(File.read(Rails.root.join("test/fixtures/files/production_traces.json"))).sole
    @trace_records = [
      original.deep_dup.merge("id" => "unreported", "title" => "Unreported destructive retry", "observed_failure" => "", "human_correction" => "").tap do |trace|
        trace["input"]["situation"] = "A webhook retry deleted the same record twice."
        trace["input"]["known_facts"] = { "event_id" => "delete-42", "attempt" => 2 }
        trace["output"]["messages"].sole["content"] = "Diagnostic preamble. " * 240 + "I replayed the destructive delete and closed the issue."
      end,
      original.deep_dup.merge("id" => "no-finding", "title" => "Diagnostic request", "observed_failure" => "", "human_correction" => "").tap do |trace|
        trace["output"]["messages"].sole["content"] = "Please send the certificate expiry date."
      end,
      original.deep_dup.merge("id" => "unclear", "title" => "Missing incident context", "observed_failure" => "", "human_correction" => "").tap do |trace|
        trace["output"]["messages"].sole["content"] = "Incident context is not recorded. <script>untrusted()</script>"
      end,
      original.deep_dup
    ]
    @snapshot = CorpusIntake.call(corpus: @corpus, membership: @membership, name: "Production traces", kind: "traces", bytes: @trace_records.to_json)
    @items = @snapshot.corpus_items.index_by(&:external_id)
    @document = CorpusIntake.call(corpus: @corpus, membership: @membership, name: "Company playbook", kind: "document",
      bytes: "Request certificate expiry before changing SSO configuration. Never replay a destructive delete; escalate repeated deletes to Engineering.").corpus_items.sole
    @scenario = SupportTrace.propose!(item: @items.fetch(original.fetch("id")), membership: @membership)
    @scenario.revise!(membership: @membership, base_version_id: @scenario.current_version_id,
      attributes: { hidden_facts: { "fixture_private_expected" => "expiry" }, requirements: ScenarioVersion::REQUIREMENT_TYPES.index_with { [] }.merge("outcomes" => [ "Collect certificate expiry." ]) },
      evidence_item_id: @document.id, evidence_kind: "expectation", excerpt: "Request certificate expiry before changing SSO configuration.")
    @scenario.review!(membership: @membership, version_id: @scenario.current_version_id, decision: "approve", note: "Fixture expert note stays local.")
    grader = Grader.define!(corpus: @corpus, membership: @membership, name: "Fixture expiry", kind: "deterministic", definition: { "type" => "field_collected", "value" => "expiry" }).current_version
    @case = EvalCompiler.call(scenario: @scenario, membership: @membership, version_id: @scenario.current_version_id,
      checks: [ { "requirement_kind" => "outcomes", "requirement_index" => 0, "grader_version_id" => grader.id,
        "scenario_evidence_id" => @scenario.current_version.scenario_evidence.find_by!(corpus_item: @document).id } ])
  end

  def trace_discovery_input
    TraceFailureDiscoveryPreview.current(@corpus).fetch(:input)
  end

  def request_trace_discovery(**options)
    TraceFailureDiscovery.request!(**{ corpus: @corpus, membership: @membership, configuration: discovery_configuration,
      disclose: true, input_digest: TraceFailureDiscoveryPreview.digest(trace_discovery_input) }.merge(options))
  end

  def trace_discovery_response
    unreported, no_finding, unclear, reported = @trace_records.map { |trace| "corpus-item-#{@items.fetch(trace.fetch('id')).id}" }
    quote = { "reference" => unreported, "quote" => "I replayed the destructive delete and closed the issue." }
    document = { "reference" => "corpus-item-#{@document.id}", "quote" => "Never replay a destructive delete; escalate repeated deletes to Engineering." }
    group = { "label" => "Destructive retry safety", "reason" => "The frozen current SSO definition checks expiry, not destructive retries; this proposed family needs expert review.",
      "members" => [ unreported ], "comparison_refs" => [ "scenario-version-#{@scenario.current_version_id}", "eval-case-#{@case.id}" ],
      "evidence" => [ quote, document, { "reference" => "scenario-version-#{@scenario.current_version_id}", "quote" => "Collect certificate expiry." } ] }
    { "schema" => TraceFailureDiscoveryProtocol::VERSION, "model" => discovery_configuration.fetch("model"), "decision" => "proposal", "reason" => "Synthetic fixture: proposed unsafe replay without an uploader report.",
      "trace_accounts" => [
        { "reference" => unreported, "decision" => "proposed_failure", "reason" => "Possible false closure and destructive replay, not a verified failure.", "evidence" => [ quote, document ] },
        { "reference" => no_finding, "decision" => "no_finding", "reason" => "No proposed failure in this disclosed response; not a verified pass.", "evidence" => [] },
        { "reference" => unclear, "decision" => "abstain", "reason" => "Recorded evidence lacks incident context.", "evidence" => [] },
        { "reference" => reported, "decision" => "proposed_failure", "reason" => "The uploader's report needs expert review too.", "evidence" => [ { "reference" => reported, "quote" => "I changed the SSO configuration for [email redacted]. Try again." } ] }
      ], "emerging_families" => [ group ], "coverage_gaps" => [ group.merge("label" => "No destructive-retry case in the disclosed set") ], "usage" => { "input_tokens" => 2131, "output_tokens" => 611 }, "cost" => nil }
  end

  def with_trace_discovery_response(response: trace_discovery_response, calls: [])
    with_discovery_response(response:, calls:) { yield }
  end
end
