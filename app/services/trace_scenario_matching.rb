class TraceScenarioMatching
  MAX_VERSIONS = 2000
  MAX_BYTES = 10.megabytes
  LIMIT = 5
  METHOD = "Local literal terms: at least two distinct shared terms excluding known-fact keys and values; ranked by corpus term rarity, then equal-fact count and version ID. No semantic matching or probability."
  Result = Data.define(:candidates, :searched_versions, :searched_bytes, :message)
  Candidate = Data.define(:version, :shared_terms, :equal_facts, :conflicting_facts, :missing_facts, :evidence, :score, :term_weights)

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
    frequencies = Hash.new(0)
    inputs.each { |_version, _evidence, words| words.each { |word| frequencies[word] += 1 } }
    weights = frequencies.transform_values { |count| Math.log(1.0 + inputs.size.to_f / count) }
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
          shared = query & words
          next if shared.size < 2
          shared -= terms([ facts, version.known_facts ].to_json)
          next if shared.size < 2
          shared.sort!
          contributions = shared.index_with { |word| weights.fetch(word) }
          equal, conflict, missing = compare_facts(facts, version.known_facts)
          Candidate.new(version, shared, equal, conflict, missing, evidence, contributions.values.sum, contributions)
        end.sort_by { |candidate| [ -candidate.score, -candidate.equal_facts.size, candidate.version.id ] }.first(LIMIT)
        result = Result.new(candidates, inputs.size, bytes, nil)
      end
      [ item.id, result ]
    end
  end

  def self.searchable_versions(corpus)
    versions = ScenarioVersion.where(corpus:, id: corpus.scenarios.where(merged_into_id: nil).select(:current_version_id))
    return [ [], 0, "Candidate corpus exceeds 2000 current versions; no text searched. Narrow the corpus." ] if versions.limit(MAX_VERSIONS + 1).count > MAX_VERSIONS

    metadata = versions.select(:id, :workspace_id, :corpus_id, :scenario_id,
      Arel.sql("octet_length(title) + octet_length(situation) + octet_length(taxonomy_label) + 2 AS matching_bytes"))
      .includes(:scenario).order(:id).to_a
    preload_source_links(metadata, evidence_scope: ScenarioEvidence.select(:id, :scenario_version_id, :corpus_item_id, :kind,
      Arel.sql("octet_length(excerpt) AS matching_bytes")))
    checked = {}
    quoted_ids = []
    bytes = 0
    metadata.select { |version| eligible?(version, refresh: false) }.each do |version|
      evidence = version.scenario_evidence.select do |entry|
        entry.kind == "expectation" && entry.corpus_item.source_snapshot.source.kind != "traces"
      end
      bytes += version["matching_bytes"] + evidence.sum { |entry| entry["matching_bytes"] + 1 }
      return [ [], bytes, "Candidate text exceeds 10 MiB; no text searched or truncated. Narrow the corpus." ] if bytes > MAX_BYTES
      checked[version.id] = version
      quoted_ids.concat(evidence.map(&:id))
    end

    loaded = versions.where(id: checked.keys).select(:id, :workspace_id, :corpus_id, :scenario_id,
      :number, :title, :situation, :taxonomy_label, :known_facts).includes(:scenario).order(:id).to_a
    excerpt = Arel::Nodes::Case.new.when(ScenarioEvidence.arel_table[:id].in(quoted_ids))
      .then(ScenarioEvidence.arel_table[:excerpt]).else(nil).as("excerpt")
    preload_source_links(loaded, evidence_scope: ScenarioEvidence.select(:id, :workspace_id, :corpus_id,
      :scenario_version_id, :corpus_item_id, :kind, excerpt))
    bytes = 0
    inputs = []
    loaded.each do |version|
      next unless eligible?(checked.fetch(version.id), refresh: false)

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

  def self.preload_source_links(versions, evidence_scope:)
    ActiveRecord::Associations::Preloader.new(records: versions, associations: :scenario_reviews,
      scope: ScenarioReview.select(:id, :scenario_version_id, :decision)).call
    ActiveRecord::Associations::Preloader.new(records: versions, associations: :scenario_evidence, scope: evidence_scope).call
    owners = versions.map(&:scenario) + versions.flat_map { |version| version.scenario_evidence.to_a }
    ActiveRecord::Associations::Preloader.new(records: owners, associations: :corpus_item,
      scope: CorpusItem.select(:id, :workspace_id, :corpus_id, :source_snapshot_id, :external_id, :title)
        .includes(source_snapshot: :source)).call
  end
  private_class_method :preload_source_links

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
      elsif trace[key].eql?(scenario[key])
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
