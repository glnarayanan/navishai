class TraceFailureDiscoveryPreview
  MAX_TRACES = 50
  MAX_DOCUMENTS = 50
  MAX_VERSIONS = 50
  MAX_CASES = 50
  MAX_LINKS = 200
  MAX_BYTES = 256.kilobytes

  def self.current(corpus)
    corpus.with_lock do
      raise CorpusIntake::Invalid, "Corpus evidence expired. Purge or renew it before discovery." if corpus.eval_definitions_expired?
      traces = corpus.current_items.where(sources: { kind: "traces" })
      documents = corpus.current_items.where(sources: { kind: "document" })
      build(corpus:, traces:, documents:)
    end
  end

  def self.fixed(discovery)
    traces = discovery.corpus_items.joins(source_snapshot: :source).where(sources: { kind: "traces" })
      .where(id: discovery.input_content.fetch("traces").map { |record| record.fetch("id") })
    documents = discovery.corpus.current_items.where(sources: { kind: "document" })
    build(corpus: discovery.corpus, traces:, documents:).fetch(:input)
  end

  def self.build(corpus:, traces:, documents:)
    versions = ScenarioVersion.where(corpus:).joins(:scenario).where("scenarios.current_version_id = scenario_versions.id AND scenarios.merged_into_id IS NULL")
    cases = corpus.eval_cases.where(scenario_version_id: versions.select(:id))
    evidence = ScenarioEvidence.where(scenario_version_id: versions.select(:id))
    checks = EvalCaseCheck.where(eval_case_id: cases.select(:id))
    unless traces.count.between?(1, MAX_TRACES) && documents.count <= MAX_DOCUMENTS && versions.count <= MAX_VERSIONS && cases.count <= MAX_CASES && evidence.count <= MAX_LINKS && checks.count <= MAX_LINKS
      raise CorpusIntake::Invalid, "Discovery needs 1–50 complete traces, at most 50 documents, 50 current scenario definitions, 50 compiled cases and 200 evidence/check links each. Nothing is sampled; use a smaller corpus."
    end
    bytes = traces.sum(CorpusAnalysis::RECORD_BYTES_SQL) + documents.sum(CorpusAnalysis::RECORD_BYTES_SQL) +
      versions.sum("octet_length(title) + octet_length(situation) + octet_length(taxonomy_label) + octet_length(known_facts::text) + octet_length(hidden_facts::text) + octet_length(requirements::text) + octet_length(follow_ups::text)") +
      evidence.sum("octet_length(excerpt)") + cases.sum("octet_length(contract::text)") + checks.joins(:grader_version).sum("octet_length(grader_versions.definition::text)")
    raise CorpusIntake::Invalid, "Complete discovery contents exceed 256 KiB. Nothing is loaded partially, sampled or truncated; use a smaller corpus." if bytes > MAX_BYTES
    versions = versions.includes(:scenario, :scenario_reviews, :scenario_evidence).order(:id).to_a
    raise CorpusIntake::Invalid, "A current scenario has stale or expired evidence. Revise it before discovery; no definitions are silently omitted." if versions.any? { |version| version.expired? || version.stale? }
    cases = cases.includes(eval_case_checks: :grader_version).order(:id).to_a
    traces = traces.includes(source_snapshot: :source).order(:id).to_a
    documents = documents.includes(source_snapshot: :source).order(:id).to_a
    input = { "traces" => traces.map { |item| SupportTrace.payload(item); source_record(item) }, "documents" => documents.map { |item| source_record(item) },
      "scenario_definitions" => versions.map do |version|
        { "reference" => "scenario-version-#{version.id}", "id" => version.id, "scenario_id" => version.scenario_id,
          "review" => version.scenario_reviews.max_by(&:id)&.decision || "needs_review",
          "definition" => version.attributes.slice(*ScenarioVersion::EDITABLE),
          "evidence" => version.scenario_evidence.sort_by(&:id).map { |quote| { "reference" => "corpus-item-#{quote.corpus_item_id}", "kind" => quote.kind, "content" => quote.excerpt } } }
      end,
      "compiled_cases" => cases.map do |item|
        { "reference" => "eval-case-#{item.id}", "id" => item.id, "scenario_version" => "scenario-version-#{item.scenario_version_id}",
          "eligible" => eligible?(item), "contract" => item.contract, "compiler_version" => item.compiler_version,
          "checks" => item.eval_case_checks.sort_by(&:id).map do |check|
            { "kind" => check.requirement_kind, "index" => check.requirement_index, "evidence_id" => check.scenario_evidence_id,
              "grader_version_id" => check.grader_version_id, "grader_kind" => check.grader_version.kind,
              "processing_version" => check.grader_version.processing_version, "definition" => check.grader_version.definition }
          end }
      end }
    raise CorpusIntake::Invalid, "Encoded complete discovery preview exceeds 256 KiB. Nothing is sampled or truncated; use a smaller corpus." if input.to_json.bytesize > MAX_BYTES
    # Linked excerpts disclose only their quoted text, not whole historic conversations.
    # Retain item lineage for every copy, including those outside current documents/traces.
    linked_ids = versions.flat_map { |version| version.scenario_evidence.map(&:corpus_item_id) }
    items = (traces + documents + corpus.corpus_items.where(id: linked_ids).select(:id, :workspace_id, :corpus_id).to_a).uniq(&:id)
    { input:, items:, versions:, cases: }
  end
  private_class_method :build

  def self.source_record(item)
    { "reference" => "corpus-item-#{item.id}", "id" => item.id, "source_id" => item.source_snapshot.source_id, "snapshot_id" => item.source_snapshot_id,
      "snapshot_digest" => item.source_snapshot.digest, "title" => item.title, "content" => item.content, "context" => item.context }
  end
  private_class_method :source_record

  def self.eligible?(item)
    item.eligible!
    true
  rescue EvalCase::Invalid
    false
  end
  private_class_method :eligible?

  def self.digest(input)
    Digest::SHA256.hexdigest(JSON.generate(canonical(input)))
  end

  def self.canonical(value)
    case value
    when Hash then value.sort.to_h.transform_values { |child| canonical(child) }
    when Array then value.map { |child| canonical(child) }
    else value
    end
  end
  private_class_method :canonical
end
