class SupportTrace
  VERSION = "support-trace-v1"
  MAX_BYTES = 100.kilobytes
  KEYS = %w[schema id title target_version observed_at input output observed_failure human_correction].freeze

  def self.records(text)
    data = JSON.parse(text)
    raise CorpusIntake::Invalid, "Upload a JSON array of support-trace-v1 records." unless data.is_a?(Array)
    data.map do |trace|
      validate!(trace)
      content = [ "Situation:\n#{trace['input']['situation']}", "Reported failure:\n#{trace['observed_failure']}",
        "Reported correction (not an expert label):\n#{trace['human_correction']}",
        *trace["input"]["knowledge"].map { |entry| "Recorded knowledge #{entry['reference']}:\n#{entry['content']}" },
        "Recorded output:\n#{JSON.pretty_generate(trace['output'])}" ].join("\n\n")
      { "id" => trace["id"], "title" => trace["title"], "content" => content, "context" => { "support_trace" => trace } }
    end
  rescue JSON::ParserError
    raise CorpusIntake::Invalid, "Upload valid JSON containing support-trace-v1 records."
  end

  def self.validate!(trace)
    valid = trace.is_a?(Hash) && trace.keys.sort == KEYS.sort && trace["schema"] == VERSION &&
      trace.to_json.bytesize <= MAX_BYTES && !trace.to_json.include?("\\u0000") &&
      text?(trace["id"], 1..255) && text?(trace["title"], 1..500) && text?(trace["target_version"], 1..120) &&
      text?(trace["observed_failure"], 0..2000) && text?(trace["human_correction"], 0..2000) &&
      trace["observed_at"].is_a?(String) && trace["observed_at"].match?(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})\z/) &&
      input?(trace["input"])
    raise CorpusIntake::Invalid, "Use support-trace-v1 with id, title, target_version, ISO 8601 observed_at, input, output, observed_failure and human_correction (at most 100 KiB per trace)." unless valid
    Date.iso8601(trace["observed_at"])
    Time.iso8601(trace["observed_at"])
    SupportOutput.validate!(trace["output"])
    trace
  rescue ArgumentError, SupportOutput::Invalid
    raise CorpusIntake::Invalid, "Each trace needs a valid observation time and support-output-v1 output."
  end

  def self.payload(item)
    source = item.source_snapshot.source.reload
    raise CorpusIntake::Invalid, "Choose an unexpired production trace." unless source.kind == "traces" && source.expires_at > Time.current
    validate!(item.context.fetch("support_trace"))
  end

  def self.propose!(item:, membership:, discovery_review: nil)
    corpus = item.corpus
    corpus.with_lock do
      corpus.authorize_writer!(membership)
      trace = payload(item)
      discovery_review.authorize_draft!(item:, membership:) if discovery_review
      existing = corpus.scenarios.find_by(corpus_item: item, parent_version_id: nil)
      return existing if existing
      discovery_review.trace_failure_discovery.ensure_evidence! if discovery_review
      raise Scenario::Invalid, "This trace has no reported failure. Review the output before proposing a failure scenario." if trace["observed_failure"].blank? && !discovery_review
      scenario = corpus.scenarios.create!(workspace: corpus.workspace, corpus_item: item)
      version = scenario.scenario_versions.create!(workspace: corpus.workspace, corpus:, created_by: membership.user,
        number: 1, origin: "mined", title: trace["title"], situation: trace["input"]["situation"],
        taxonomy_label: trace["title"], importance: "normal", known_facts: trace["input"]["known_facts"], hidden_facts: {},
        requirements: ScenarioVersion::REQUIREMENT_TYPES.index_with { [] },
        selection_reason: discovery_review ? "Expert accepted a proposed failure in discovery #{discovery_review.trace_failure_discovery_id}, review #{discovery_review.id}. Model text and uploaded corrections supply no approved expectations." : "Reported production failure in source record #{item.external_id}. The recorded correction is not an approved expectation.", created_at: Time.current)
      version.scenario_evidence.create!(workspace: corpus.workspace, corpus:, corpus_item: item, kind: "expectation", excerpt: discovery_review ? discovery_review.source_excerpt : item.content.first(4000))
      scenario.update!(current_version: version)
      AuditEvent.record!(action: "scenario.mined", source: :web, workspace: corpus.workspace, actor: membership.user, subject: version, metadata: { version: 1 })
      scenario
    end
  end

  def self.text?(value, range)
    value.is_a?(String) && range.cover?(value.length)
  end

  def self.input?(input)
    input.is_a?(Hash) && input.keys.sort == %w[knowledge known_facts situation] && text?(input["situation"], 1..10_000) &&
      input["known_facts"].is_a?(Hash) && input["known_facts"].to_json.bytesize <= 10.kilobytes &&
      input["knowledge"].is_a?(Array) && input["knowledge"].size <= 100 &&
      input["knowledge"].all? { |entry| entry.is_a?(Hash) && entry.keys.sort == %w[content reference] && text?(entry["reference"], 1..255) && text?(entry["content"], 1..4000) }
  end
  private_class_method :text?, :input?
end
