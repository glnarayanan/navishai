class TraceScenarioMatching
  MAX_VERSIONS = 2000
  MAX_BYTES = 10.megabytes
  LIMIT = 5
  METHOD = "Local literal terms: at least two distinct shared terms excluding known-fact keys and values; ordered by shared-term count, then equal-fact count, then version ID. No semantic matching or probability."
  Result = Data.define(:candidates, :searched_versions, :searched_bytes, :message)
  Candidate = Data.define(:version, :shared_terms, :equal_facts, :conflicting_facts, :missing_facts, :evidence)

  def self.call(item:)
    call_all(items: [ item ]).fetch(item.id)
  end

  def self.call_all(items:)
    return {} if items.empty?
    corpus = items.first.corpus
    raise CorpusIntake::Invalid, "Match traces from one corpus at a time." unless items.all? { |item| item.corpus_id == corpus.id && item.workspace_id == corpus.workspace_id }
    if corpus.eval_definitions_expired?
      return items.to_h { |item| [ item.id, Result.new([], 0, 0, "Matches hidden because a corpus source has expired.") ] }
    end
    inputs, bytes, message = corpus.with_lock { searchable_versions(corpus) }
    items.to_h do |item|
      trace = SupportTrace.payload(item)
      if trace["observed_failure"].blank?
        result = Result.new([], 0, 0, "No reported failure to match.")
      elsif message
        result = Result.new([], 0, bytes, message)
      else
        facts = trace.fetch("input").fetch("known_facts")
        query = terms(trace["input"]["situation"] + "\n" + trace["observed_failure"])
        candidates = inputs.filter_map do |version, evidence, words|
          fact_terms = terms([ facts, version.known_facts ].to_json)
          shared = (query & words) - fact_terms
          next if shared.size < 2
          equal, conflict, missing = compare_facts(facts, version.known_facts)
          Candidate.new(version, shared.sort, equal, conflict, missing, evidence)
        end.sort_by { |candidate| [ -candidate.shared_terms.size, -candidate.equal_facts.size, candidate.version.id ] }.first(LIMIT)
        result = Result.new(candidates, inputs.size, bytes, nil)
      end
      [ item.id, result ]
    end
  end

  def self.searchable_versions(corpus)
    versions = ScenarioVersion.where(corpus:, id: corpus.scenarios.where(merged_into_id: nil).select(:current_version_id))
    return [ [], 0, "Candidate corpus exceeds 2000 current versions; no text searched. Narrow the corpus." ] if versions.limit(MAX_VERSIONS + 1).count > MAX_VERSIONS

    versions = versions
      .includes(:scenario_reviews, scenario: { corpus_item: { source_snapshot: :source } }, scenario_evidence: { corpus_item: { source_snapshot: :source } })
      .order(:id).limit(MAX_VERSIONS + 1).to_a
    bytes = 0
    inputs = []
    versions.select { |version| eligible?(version, refresh: false) }.each do |version|
      # Trace excerpts can contain imported corrections and outputs; never search them.
      evidence = version.scenario_evidence.select do |entry|
        entry.kind == "expectation" && entry.corpus_item.source_snapshot.source.kind != "traces"
      end
      text = [ version.title, version.situation, version.taxonomy_label, *evidence.map(&:excerpt) ].join("\n")
      bytes += text.bytesize
      return [ [], bytes, "Candidate text exceeds 10 MiB; no text searched or truncated. Narrow the corpus." ] if bytes > MAX_BYTES
      inputs << [ version, evidence, text ]
    end
    [ inputs.map { |version, evidence, text| [ version, evidence, terms(text) ] }, bytes, nil ]
  end
  private_class_method :searchable_versions

  def self.eligible?(version, refresh: true)
    scenario = refresh ? version.scenario.reload : version.scenario
    evidence = version.scenario_evidence.to_a
    origin = scenario.corpus_item.source_snapshot.source
    origin.reload if refresh
    return false unless scenario.current_version_id == version.id && scenario.merged_into_id.nil? && origin.expires_at > Time.current && evidence.any?
    decision = refresh ? version.latest_review&.decision : version.scenario_reviews.max_by(&:id)&.decision
    return false if %w[reject merge].include?(decision)
    evidence.all? do |entry|
      snapshot = entry.corpus_item.source_snapshot
      source = snapshot.source
      source.reload if refresh
      source.expires_at > Time.current && (source.kind != "document" || source.current_snapshot_id == snapshot.id)
    end
  end

  def self.compare_facts(trace, scenario)
    equal = {}
    conflict = {}
    missing = {}
    (trace.keys | scenario.keys).sort.each do |key|
      pair = { "trace" => trace[key], "scenario" => scenario[key] }
      if !trace.key?(key) || !scenario.key?(key)
        missing[key] = pair.merge("missing_from" => trace.key?(key) ? "scenario" : "trace")
      elsif trace[key].class == scenario[key].class && trace[key] == scenario[key]
        equal[key] = trace[key]
      else
        conflict[key] = pair
      end
    end
    [ equal, conflict, missing ]
  end

  def self.terms(text)
    CorpusDiscovery.terms(text).uniq
  end
  private_class_method :terms
end
