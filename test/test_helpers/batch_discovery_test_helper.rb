require_relative "model_discovery_test_helper"

module BatchDiscoveryTestHelper
  include ModelDiscoveryTestHelper

  def build_batch_corpus
    build_discovery_corpus
    # The dangerous minority is deliberately beyond the first 99 conversations.
    records = 105.times.map { |index| { id: "identity-#{index}", title: "Identity #{index}", content: "SSO stopped after signing certificate rotation." } }
    records << @records.last
    @snapshot = CorpusIntake.call(corpus: @corpus, membership: @membership, name: "History", kind: "conversations", bytes: records.to_json)
    @items = @snapshot.corpus_items.index_by(&:external_id)
  end

  def batch_plan
    BatchCorpusDiscovery.plan(CorpusAnalysis.current_inputs(corpus: @corpus, model: true, batch: true))
  end

  def request_batch_analysis(**options)
    plan = batch_plan
    CorpusAnalysis.request!(**{ corpus: @corpus, membership: @membership, scenario_limit: 2, configuration: discovery_configuration,
      processing_method: "model_batch", disclose: true, input_digest: plan.fetch("source_digest"), call_plan_digest: ModelCorpusDiscovery.digest(plan) }.merge(options))
  end

  def batch_response(payload)
    return merge_response(payload) if payload.fetch("schema") == BatchCorpusDiscovery::MERGE_VERSION
    conversations = payload.fetch("records").select { |record| record.fetch("kind") == "conversations" }
    rare, common = conversations.partition { |record| record.fetch("content").include?("data loss") }
    label = common.size > 20 ? "Certificate turnover" : "Trust material refresh"
    clusters = [ [ common, label ], [ rare, "Unsafe delete retries" ] ].filter_map do |records, family|
      next if records.empty?
      { "label" => family, "reason" => "Synthetic source-backed grouping.", "possible_documentation_gap" => family == "Unsafe delete retries",
        "members" => records.pluck("reference"), "evidence" => records.map { |record| record.slice("reference").merge("quote" => record.fetch("content").split(". ").first.then { |text| text.end_with?(".") ? text : "#{text}." }) } }
    end
    document = payload.fetch("records").find { |record| record.fetch("kind") == "document" }.fetch("reference")
    candidates = clusters.map do |cluster|
      dangerous = cluster.fetch("label") == "Unsafe delete retries"
      { "reference" => cluster.fetch("members").first, "reason" => "Synthetic representative or minority risk.",
        "scenario" => { "title" => dangerous ? "Destructive replay" : "Identity diagnostics", "situation" => "Investigate the reported source-backed problem.",
          "taxonomy_label" => cluster.fetch("label"), "importance" => dangerous ? "critical" : "high", "known_facts" => {}, "hidden_facts" => {},
          "requirements" => ScenarioVersion::REQUIREMENT_TYPES.index_with { [] }.merge("outcomes" => [ "Escalate based on company evidence." ]) },
        "evidence_links" => [ { "kind" => "outcomes", "index" => 0, "reference" => document,
          "quote" => dangerous ? "Escalate repeated deletes with data loss to Engineering." : "Request the signing certificate expiry before changing SSO configuration." } ] }
    end
    { "schema" => ModelCorpusDiscovery::VERSION, "model" => discovery_configuration.fetch("model"), "decision" => "proposal", "reason" => "Synthetic batch.", "clusters" => clusters, "candidates" => candidates, "usage" => nil, "cost" => nil }
  end

  def merge_response(payload)
    dangerous, common = payload.fetch("clusters").partition { |cluster| cluster.fetch("label") == "Unsafe delete retries" }
    families = [ [ common, "Company identity lifecycle" ], [ dangerous, "Destructive delivery" ] ].filter_map do |clusters, label|
      next if clusters.empty?
      { "label" => label, "reason" => "Synthetic merged family.", "possible_documentation_gap" => label == "Destructive delivery", "cluster_refs" => clusters.pluck("reference") }
    end
    candidates = payload.fetch("candidates")
    rare = candidates.find { |candidate| candidate.dig("definition", "scenario", "importance") == "critical" }
    representative = candidates.find { |candidate| candidate.dig("definition", "scenario", "importance") != "critical" }
    { "schema" => BatchCorpusDiscovery::MERGE_VERSION, "model" => discovery_configuration.fetch("model"), "decision" => "proposal", "reason" => "Synthetic exact merge preserving minority risk.",
      "families" => families, "candidate_refs" => [ rare, representative ].compact.pluck("reference"), "usage" => nil, "cost" => nil }
  end

  def with_batch_responses(calls: [], change: nil, after_call: nil)
    with_corpus_approval do
      with_test_method(Resolv, :getaddresses, ->(*) { [ "93.184.216.34" ] }) do
        with_test_method(EvaluationHttp, :perform, ->(_uri, request, _address) do
          payload = JSON.parse(request.body)
          calls << request
          value = batch_response(payload)
          change&.call(value, payload)
          after_call&.call(calls.size)
          value.to_json
        end) { yield }
      end
    end
  end
end
