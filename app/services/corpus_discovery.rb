class CorpusDiscovery
  STOP_WORDS = %w[a an and are as at be been but by can could customer did do does for from had has have how i if in into is it its no not of on or our please support that the their them then there these they this to user was we were what when which will with would you your].freeze
  SIGNALS = {
    "escalation mention" => /\b(engineering|escalat\w*)\b/i,
    "reopen / unresolved mention" => /\b(reopen\w*|unresolved|still broken|not resolved)\b/i,
    "risk mention" => /\b(data loss|security|outage|duplicate (?:writes|invoices)|suspended)\b/i,
    "diagnostic evidence mention" => /\b(logs?|metadata|reproduc\w*|certificate|trace)\b/i
  }.freeze
  MAX_TERM_ENTRIES = 2_000_000
  MAX_DISTINCT_TERMS = 250_000
  MAX_SEED_COMPARISONS = 2_000_000

  def self.call(analysis)
    analysis.fixed_inputs(item_ids: [])
    full_text = analysis.full_text?
    bounded = analysis.large? || full_text
    method_label = analysis.large_full_text? ? "Large full-text local" : (full_text ? "Full-text local" : "Streaming local")
    conversations = []
    doc_terms = {}
    documents = 0
    term_entries = 0
    frequencies = Hash.new(0)
    inputs = analysis.corpus_items.joins(source_snapshot: :source).reorder(:external_id, :id)
    inputs.in_batches(of: 100, cursor: [ :external_id, :id ]) do |batch|
      batch.pluck(:id, :external_id, :title, :content, "sources.kind",
        Arel.sql("corpus_items.context -> 'impact' = '\"critical\"'::jsonb"),
        Arel.sql("corpus_items.context -> 'reopened' = 'true'::jsonb")).each do |id, external_id, title, content, kind, critical, reopened|
        if kind == "document"
          documents += 1
          terms(content).each { |word| doc_terms[word] = true }
        else
          conversations << { id:, external_id:, title:, counts: terms(title + " " + (full_text ? content : content.first(4000))).tally,
            signals: signals(content:, critical:, reopened:) }
          term_entries += conversations.last[:counts].size
          conversations.last[:counts].each_key { |word| frequencies[word] += 1 }
        end
        raise CorpusIntake::Invalid, "#{method_label} discovery exceeded its term-entry or vocabulary budget; no proposals saved. Use a smaller corpus; nothing is sampled or retried." if bounded && (term_entries > MAX_TERM_ENTRIES || doc_terms.size > MAX_DISTINCT_TERMS || frequencies.size > MAX_DISTINCT_TERMS)
      end
    end
    raise CorpusIntake::Invalid, "Add historical conversations before analysis." if conversations.empty?
    raise CorpusIntake::Invalid, "#{method_label} discovery exceeded its vocabulary budget; no proposals saved. Use a smaller corpus; nothing is sampled or retried." if bounded && (frequencies.keys | doc_terms.keys).size > MAX_DISTINCT_TERMS
    vectors = conversations.to_h { |record| [ record[:id], record[:counts].transform_values(&:to_f) ] }
    vectors.each_value do |vector|
      vector.each { |word, count| vector[word] = count * Math.log(1.0 + conversations.size.to_f / frequencies.fetch(word)) }
    end
    squared_lengths = vectors.transform_values { |vector| vector.values.sum { |value| value * value } }
    groups = []
    seeds = Hash.new { |index, word| index[word] = [] }
    comparisons = 0
    conversations.each do |record|
      vector = vectors.fetch(record[:id])
      # A seed without a shared term has cosine zero and cannot meet 0.3.
      candidates = vector.keys.flat_map { |word| seeds[word] }.uniq.sort
      comparisons += candidates.size
      raise CorpusIntake::Invalid, "#{method_label} discovery exceeded its seed-comparison budget; no proposals saved. Use a smaller corpus; nothing is sampled or retried." if bounded && comparisons > MAX_SEED_COMPARISONS
      index, best_score = nil, -1
      candidates.each do |position|
        seed_id = groups[position].first[:id]
        score = similarity(vector, vectors.fetch(seed_id), a_squared: squared_lengths.fetch(record[:id]), b_squared: squared_lengths.fetch(seed_id))
        index, best_score = position, score if score > best_score
      end
      if index && best_score >= 0.3
        groups[index] << record
      else
        vector.each_key { |word| seeds[word] << groups.size }
        groups << [ record ]
      end
    end
    proposals = groups.map do |group|
      counts = Hash.new(0)
      group.each { |record| record[:counts].each { |word, count| counts[word] += count } }
      group_terms = counts.sort_by { |word, count| [ -count, word ] }.first(3).map(&:first)
      { label: group_terms.presence&.join(" / ") || group.first[:title].first(120), members: group,
        documentation_gap: group_terms.none? { |word| doc_terms.key?(word) } }
    end
    ordered = proposals.sort_by { |proposal| [ -proposal[:members].size, proposal[:label] ] }
    risk_cases = ordered.flat_map do |proposal|
      proposal[:members].select { |member| (member[:signals] & [ "reported critical impact", "risk mention", "reported reopen" ]).any? }
        .map { |member| [ proposal, member, "Risk / reopen signal prioritised ahead of volume" ] }
    end.sort_by { |entry| [ entry[1][:signals].include?("reported critical impact") ? 0 : 1, -entry[1][:signals].size, entry[1][:external_id] ] }
    representatives = ordered.map do |proposal|
      centroid = Hash.new(0)
      proposal[:members].each { |member| vectors.fetch(member[:id]).each { |word, value| centroid[word] += value } }
      centroid_squared = centroid.values.sum { |value| value * value }
      representative = proposal[:members].max_by { |member| similarity(vectors.fetch(member[:id]), centroid, a_squared: squared_lengths.fetch(member[:id]), b_squared: centroid_squared) }
      [ proposal, representative, "Nearest to this cluster's term centroid" ]
    end
    additional = ordered.flat_map { |proposal| proposal[:members].map { |member| [ proposal, member, "Additional issue-family example" ] } }
    selected = (risk_cases + representatives + additional).uniq { |entry| entry[1][:id] }.first(analysis.scenario_limit)
    choices = selected.index_by { |entry| entry[1][:id] }
    ordered.each do |proposal|
      cluster = analysis.issue_clusters.create!(workspace: analysis.workspace, corpus: analysis.corpus,
        proposed_label: proposal[:label], signals: { "count" => proposal[:members].size, "possible_documentation_gap" => proposal[:documentation_gap] })
      proposal[:members].each_slice(1000) do |members|
        rows = members.map do |member|
          choice = choices[member[:id]]
          reason = choice && "#{choice[2]}; #{member[:signals].presence&.join(', ') || 'no keyword risk signal'}; cluster size #{proposal[:members].size}. Expert review required."
          { workspace_id: analysis.workspace_id, corpus_id: analysis.corpus_id, issue_cluster_id: cluster.id,
            corpus_item_id: member[:id], signals: member[:signals], selection_reason: reason }
        end
        ClusterMember.insert_all!(rows, returning: false)
      end
    end
    { "conversations" => conversations.size, "documents" => documents, "clusters" => groups.size,
      "selected" => selected.size, "represented_clusters" => selected.map(&:first).uniq.size,
      "risk_mentions" => conversations.count { |record| record[:signals].any? }, "text_window" => full_text ? "complete" : 4000, "similarity_threshold" => 0.3 }
  end

  def self.terms(text)
    ActionView::Base.full_sanitizer.sanitize(text).downcase.scan(/[[:alpha:]][[:alnum:]_-]{2,}/).reject { |word| STOP_WORDS.include?(word) }
  end

  def self.signals(content:, critical:, reopened:)
    result = SIGNALS.filter_map { |label, pattern| label if content.match?(pattern) }
    result << "reported critical impact" if critical
    result << "reported reopen" if reopened
    result
  end
  private_class_method :signals

  def self.similarity(a, b, a_squared: a.values.sum { |value| value * value }, b_squared: b.values.sum { |value| value * value })
    denominator = Math.sqrt(a_squared * b_squared)
    return 0 if denominator.zero?

    a.sum { |word, value| value * b.fetch(word, 0) } / denominator
  end
  private_class_method :similarity
end
