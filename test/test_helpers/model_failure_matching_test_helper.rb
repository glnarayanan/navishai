require_relative "../support/failure_matching_fixture"
require_relative "http_target_test_helper"

module ModelFailureMatchingTestHelper
  include FailureMatchingFixture
  include HttpTargetTestHelper

  def build_model_matching_fixture
    build_failure_matching_fixture
    @workspace = @corpus.workspace
    policy = CorpusIntake.call(corpus: @corpus, membership: @membership, name: "Quota policy", kind: "document",
      bytes: "Retry after cooldown.\nNever resend at once.\nQuota diagnostics need usage evidence.").corpus_items.sole
    @paraphrase = matching_version(title: "Request quota", situation: "Request quota exhausted; retry after cooldown.", facts: { "plan" => "enterprise" }, item: policy, excerpt: policy.content)
    @paraphrase = @paraphrase.scenario.revise!(membership: @membership, base_version_id: @paraphrase.id,
      attributes: { hidden_facts: { "diagnosis" => "PRIVATE_HIDDEN_FACT" }, requirements: ScenarioVersion::REQUIREMENT_TYPES.index_with { [] }.merge("outcomes" => [ "Retry after cooldown." ], "forbidden" => [ "Never resend at once." ]) })
    @paraphrase.scenario.review!(membership: @membership, version_id: @paraphrase.id, decision: "approve", note: "PRIVATE_REVIEW_NOTE")
    @negated = matching_version(title: "Quota available", situation: "Request quota is NOT exhausted; immediate retries are allowed.", facts: { "plan" => "enterprise" }, item: policy, excerpt: "Quota diagnostics need usage evidence.")
    trace = JSON.parse(File.read(Rails.root.join("test/fixtures/files/production_traces.json"))).sole
    trace.merge!("id" => "quota-paraphrase", "title" => "Traffic ceiling failure", "observed_failure" => "Assistant resends immediately.", "human_correction" => "PRIVATE_IMPORTED_CORRECTION")
    trace["input"] = { "situation" => "Traffic ceiling reached; wait before resending.", "known_facts" => { "plan" => "enterprise" }, "knowledge" => [] }
    trace["output"]["messages"] = [ { "role" => "assistant", "content" => "I will resend immediately." } ]
    @item = CorpusIntake.call(corpus: @corpus, membership: @membership, name: "Quota failure trace", kind: "traces", bytes: [ trace ].to_json).corpus_items.sole
  end

  def matching_configuration
    { "endpoint" => HTTP_ENDPOINT, "model" => "matching-fixture-v1", "settings" => { "temperature" => 0, "max_output_tokens" => 4096, "seed" => 37 } }
  end

  def request_matching(**options)
    input = ModelFailureMatcher.input(@item)
    ModelFailureMatching.request!(item: @item, membership: @membership, configuration: matching_configuration,
      input_digest: ModelFailureMatcher.digest(input), request_digest: ModelFailureMatcher.request_digest(input, matching_configuration),
      disclose: true, endpoint_confirmation: HTTP_ENDPOINT, **options)
  end

  def matching_response
    { "schema" => "model-failure-matching-v1", "model" => "matching-fixture-v1", "decision" => "suggestions", "suggestions" => [
      { "scenario_version_id" => @paraphrase.id, "decision" => "match", "reason" => "Authored fixture: traffic ceiling and request quota describe the same limit; immediate resend conflicts with cooldown.",
        "evidence" => [ { "reference" => "trace-#{@item.id}", "quote" => "Traffic ceiling reached; wait before resending." },
          { "reference" => "scenario-version-#{@paraphrase.id}", "quote" => "Request quota exhausted; retry after cooldown." } ] },
      { "scenario_version_id" => @negated.id, "decision" => "no_match", "reason" => "Authored fixture: NOT exhausted contradicts the trace's reached ceiling despite the related vocabulary.",
        "evidence" => [ { "reference" => "trace-#{@item.id}", "quote" => "Traffic ceiling reached" },
          { "reference" => "scenario-version-#{@negated.id}", "quote" => "Request quota is NOT exhausted" } ] },
      { "scenario_version_id" => @version.id, "decision" => "uncertain", "reason" => "Authored fixture: certificate evidence does not settle the reported traffic ceiling; no diagnosis is supported.",
        "evidence" => [ { "reference" => "trace-#{@item.id}", "quote" => "Assistant resends immediately." },
          { "reference" => "scenario-evidence-#{@version.scenario_evidence.sole.id}", "quote" => "request expiry evidence" } ] }
    ], "usage" => { "input_tokens" => 811, "output_tokens" => 303 }, "cost" => nil }
  end

  def with_matching_approval(workspace_id: @workspace.id, endpoint: HTTP_ENDPOINT)
    original = ENV["NAVISHAI_MATCHING_ENDPOINTS"]
    ENV["NAVISHAI_MATCHING_ENDPOINTS"] = [ { workspace_id:, endpoint:, bearer_token: "test-only-matching-token" } ].to_json
    yield
  ensure
    original ? ENV["NAVISHAI_MATCHING_ENDPOINTS"] = original : ENV.delete("NAVISHAI_MATCHING_ENDPOINTS")
  end

  def with_matching_response(response: matching_response, calls: [])
    with_matching_approval do
      with_test_method(Resolv, :getaddresses, ->(*) { [ "93.184.216.34" ] }) do
        with_test_method(EvaluationHttp, :perform, ->(_uri, request, _address) { calls << request; response.to_json }) { yield }
      end
    end
  end
end
