class IssueCluster < ImmutableRecord
  belongs_to :workspace
  belongs_to :corpus
  belongs_to :corpus_analysis
  has_many :cluster_members

  def label
    corpus_analysis.latest_taxonomy&.labels&.fetch(id.to_s, nil) || proposed_label
  end

  # Derived from complete fixed source records, never saved proposal importance.
  # Groups overlap; each denominator is the full family, not the filtered page.
  def source_groups
    analysis = corpus_analysis
    raise ActiveRecord::RecordNotFound if analysis.workspace_id != workspace_id || analysis.corpus_id != corpus_id || analysis.expired?
    relation = cluster_members.joins(:corpus_item)
    raise ActiveRecord::RecordNotFound if relation.count > CorpusAnalysis::MAX_ITEMS || relation.sum("octet_length(corpus_items.content) + octet_length(corpus_items.context::text)") > 10.megabytes

    members = cluster_members.includes(corpus_item: { source_snapshot: :source }).order(:corpus_item_id, :id).to_a
    fixed_ids = analysis.corpus_items.pluck(:id)
    raise ActiveRecord::RecordNotFound unless members.all? { |member| member.workspace_id == workspace_id && member.corpus_id == corpus_id && fixed_ids.include?(member.corpus_item_id) }

    groups = { "All records" => members }
    %w[escalated reopened failed].each do |field|
      groups["context.#{field}: true"] = members.select { |member| member.corpus_item.context[field].equal?(true) }
      groups["context.#{field}: false"] = members.select { |member| member.corpus_item.context[field].equal?(false) }
      groups["context.#{field}: missing / nonboolean"] = members.reject { |member| [ true, false ].any? { |value| member.corpus_item.context[field].equal?(value) } }
    end
    groups["reported critical impact"] = members.select { |member| member.corpus_item.context["impact"] == "critical" }
    CorpusDiscovery::SIGNALS.each do |name, pattern|
      groups[name] = members.select { |member| member.corpus_item.content.match?(pattern) }
    end
    groups
  end
end
