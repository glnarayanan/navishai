class CorpusDiscovery
  STOP_WORDS = %w[a an and are as at be been but by can could customer did do does for from had has have how i if in into is it its no not of on or our please support that the their them then there these they this to user was we were what when which will with would you your].freeze
  SIGNALS = {
    "escalation mention" => /\b(engineering|escalat\w*)\b/i,
    "reopen / unresolved mention" => /\b(reopen\w*|unresolved|still broken|not resolved)\b/i,
    "risk mention" => /\b(data loss|security|outage|duplicate (?:writes|invoices)|suspended)\b/i,
    "diagnostic evidence mention" => /\b(logs?|metadata|reproduc\w*|certificate|trace)\b/i
  }.freeze

  def self.call(analysis)
    items = analysis.corpus_items.includes(source_snapshot: :source).order(:external_id, :id).to_a
    raise CorpusIntake::Invalid, "Source inputs expired; create a new analysis." if items.any? { |item| item.source_snapshot.source.expires_at <= Time.current }
    documents, conversations = items.partition { |item| item.source_snapshot.source.kind == "document" }
    raise CorpusIntake::Invalid, "Add historical conversations before analysis." if conversations.empty?
    tokens = conversations.to_h { |item| [ item.id, terms(item.title + " " + item.content.first(4000)) ] }
    frequencies = tokens.values.flat_map(&:uniq).tally
    vectors = tokens.transform_values { |words| words.tally.transform_values(&:to_f) }
    vectors.each_value do |vector|
      vector.each { |word, count| vector[word] = count * Math.log(1.0 + conversations.size.to_f / frequencies.fetch(word)) }
    end
    groups = []
    conversations.each do |item|
      vector = vectors.fetch(item.id)
      group = groups.max_by { |candidate| similarity(vector, vectors.fetch(candidate.first.id)) }
      if group && similarity(vector, vectors.fetch(group.first.id)) >= 0.3
        group << item
      else
        groups << [ item ]
      end
    end
    doc_terms = documents.flat_map { |document| terms(document.content) }.uniq
    proposals = groups.map do |group|
      group_terms = group.flat_map { |item| tokens.fetch(item.id) }.tally.sort_by { |word, count| [ -count, word ] }.first(3).map(&:first)
      members = group.map { |item| { item:, signals: signals(item) } }
      { label: group_terms.presence&.join(" / ") || group.first.title.first(120), members:,
        documentation_gap: (group_terms & doc_terms).empty? }
    end
    ordered = proposals.sort_by { |proposal| [ -proposal[:members].size, proposal[:label] ] }
    risk_cases = ordered.flat_map do |proposal|
      proposal[:members].select { |member| (member[:signals] & [ "reported critical impact", "risk mention", "reported reopen" ]).any? }
        .map { |member| [ proposal, member, "Risk / reopen signal prioritised ahead of volume" ] }
    end.sort_by { |entry| [ entry[1][:signals].include?("reported critical impact") ? 0 : 1, -entry[1][:signals].size, entry[1][:item].external_id ] }
    representatives = ordered.map do |proposal|
      centroid = Hash.new(0)
      proposal[:members].each { |member| vectors.fetch(member[:item].id).each { |word, value| centroid[word] += value } }
      representative = proposal[:members].max_by { |member| similarity(vectors.fetch(member[:item].id), centroid) }
      [ proposal, representative, "Nearest to this cluster's term centroid" ]
    end
    additional = ordered.flat_map { |proposal| proposal[:members].map { |member| [ proposal, member, "Additional issue-family example" ] } }
    selected = (risk_cases + representatives + additional).uniq { |entry| entry[1][:item].id }.first(analysis.scenario_limit)
    ordered.each do |proposal|
      cluster = analysis.issue_clusters.create!(workspace: analysis.workspace, corpus: analysis.corpus,
        proposed_label: proposal[:label], signals: { "count" => proposal[:members].size, "possible_documentation_gap" => proposal[:documentation_gap] })
      proposal[:members].each do |member|
        choice = selected.find { |entry| entry[1].equal?(member) }
        reason = choice && "#{choice[2]}; #{member[:signals].presence&.join(', ') || 'no keyword risk signal'}; cluster size #{proposal[:members].size}. Expert review required."
        cluster.cluster_members.create!(workspace: analysis.workspace, corpus: analysis.corpus,
          corpus_item: member[:item], signals: member[:signals], selection_reason: reason)
      end
    end
    { "conversations" => conversations.size, "documents" => documents.size, "clusters" => groups.size,
      "selected" => selected.size, "represented_clusters" => selected.map(&:first).uniq.size,
      "risk_mentions" => conversations.count { |item| signals(item).any? }, "text_window" => 4000, "similarity_threshold" => 0.3 }
  end

  def self.terms(text)
    ActionView::Base.full_sanitizer.sanitize(text).downcase.scan(/[[:alpha:]][[:alnum:]_-]{2,}/).reject { |word| STOP_WORDS.include?(word) }
  end

  def self.signals(item)
    result = SIGNALS.filter_map { |label, pattern| label if item.content.match?(pattern) }
    result << "reported critical impact" if item.context["impact"] == "critical"
    result << "reported reopen" if item.context["reopened"] == true
    result
  end
  private_class_method :signals

  def self.similarity(a, b)
    denominator = Math.sqrt(a.values.sum { |value| value * value } * b.values.sum { |value| value * value })
    return 0 if denominator.zero?

    a.sum { |word, value| value * b.fetch(word, 0) } / denominator
  end
  private_class_method :similarity
end
