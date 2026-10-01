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
    corpus.with_lock do
      raise ActiveRecord::RecordNotFound if analysis.workspace_id != workspace_id || analysis.corpus_id != corpus_id || analysis.expired?
      members = cluster_members.joins(:corpus_item).order(:corpus_item_id, :id)
      raise ActiveRecord::RecordNotFound if members.count > CorpusAnalysis::MAX_ITEMS || members.sum(CorpusAnalysis::RECORD_BYTES_SQL) > CorpusAnalysis::MAX_RECORD_BYTES
      raise ActiveRecord::RecordNotFound if members.where.not(workspace_id:, corpus_id:).exists? || members.where.not(corpus_item_id: analysis.corpus_items.select(:id)).exists?

      groups = { "All records" => members }
      %w[escalated reopened failed].each do |field|
        groups["context.#{field}: true"] = members.where("corpus_items.context -> ? = 'true'::jsonb", field)
        groups["context.#{field}: false"] = members.where("corpus_items.context -> ? = 'false'::jsonb", field)
        groups["context.#{field}: missing / nonboolean"] = members.where("(corpus_items.context -> ?) IS DISTINCT FROM 'true'::jsonb AND (corpus_items.context -> ?) IS DISTINCT FROM 'false'::jsonb", field, field)
      end
      groups["reported critical impact"] = members.where("corpus_items.context -> 'impact' = '\"critical\"'::jsonb")
      mentions = CorpusDiscovery::SIGNALS.transform_values { [] }
      CorpusItem.where(id: members.select(:corpus_item_id)).in_batches(of: 100) do |batch|
        batch.pluck(:id, :content).each do |id, content|
          CorpusDiscovery::SIGNALS.each { |name, pattern| mentions.fetch(name) << id if content.match?(pattern) }
        end
      end
      mentions.each { |name, ids| groups[name] = members.where(corpus_item_id: ids) }
      groups
    end
  end
end
