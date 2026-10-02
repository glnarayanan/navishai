require_relative "batch_discovery_test_helper"

module RelationshipDiscoveryTestHelper
  include BatchDiscoveryTestHelper

  def build_relationship_corpus
    build_discovery_corpus
    records = 106.times.map do |index|
      content = case index
      when 0 then "Agent: Rotate first, then collect expiry."
      when 99 then "Playbook: Collect expiry before rotation."
      else "SSO stopped after signing certificate rotation."
      end
      { id: "report-#{index}", title: "Authored report #{index}", content: }
    end
    @snapshot = CorpusIntake.call(corpus: @corpus, membership: @membership, name: "History", kind: "conversations", bytes: records.to_json)
    @items = @snapshot.corpus_items.index_by(&:external_id)
  end

  def request_relationship_analysis(**options)
    plan = batch_plan(version: BatchCorpusDiscovery::RELATIONSHIPS_VERSION)
    CorpusAnalysis.request!(**{ corpus: @corpus, membership: @membership, scenario_limit: 2, configuration: discovery_configuration,
      processing_method: "model_batch_relationships", disclose: true, input_digest: plan.fetch("source_digest"),
      call_plan_digest: ModelCorpusDiscovery.digest(plan) }.merge(options))
  end

  def relationship_response(payload)
    if payload["schema"] == BatchCorpusDiscovery::MERGE_RELATIONSHIPS_VERSION
      response = merge_response(payload.merge("schema" => BatchCorpusDiscovery::MERGE_OBSERVATIONS_VERSION))
      anchors = payload.fetch("observations").map { |entry| { "observation_ref" => entry.fetch("reference"), "evidence_index" => 0 } }
      response.merge("schema" => payload.fetch("schema"), "relationships" => [ {
        "kind" => "contradictory_guidance", "status" => "proposed", "summary" => "These separate reports place rotation and expiry collection in different orders.",
        "uncertainty" => "Different account scope or dates may explain these reports; an expert must check both.", "anchor_refs" => anchors } ])
    else
      response = batch_response(payload)
      record = payload.fetch("records").find { |entry| entry["kind"] == "conversations" }
      response["observations"] = [ { "kind" => "troubleshooting_progression", "status" => "proposed",
        "summary" => "Review this reported diagnostic order without treating it as policy.",
        "uncertainty" => "The report does not prove which order is correct.",
        "evidence" => [ record.slice("reference").merge("quote" => record.fetch("content")),
          { "reference" => "corpus-item-#{@document.id}", "quote" => "Request the signing certificate expiry before changing SSO configuration." } ] } ]
      response
    end
  end

  def with_relationship_responses(calls: [], change: nil, after_call: nil)
    with_corpus_approval do
      with_test_method(Resolv, :getaddresses, ->(*) { [ "93.184.216.34" ] }) do
        with_test_method(EvaluationHttp, :perform, ->(_uri, request, _address) do
          payload = JSON.parse(request.body)
          calls << request
          response = relationship_response(payload)
          change&.call(response, payload)
          after_call&.call(calls.size)
          response.to_json
        end) { yield }
      end
    end
  end
end
