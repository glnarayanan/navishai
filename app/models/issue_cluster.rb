class IssueCluster < ImmutableRecord
  belongs_to :workspace
  belongs_to :corpus
  belongs_to :corpus_analysis
  has_many :cluster_members

  def label
    corpus_analysis.latest_taxonomy&.labels&.fetch(id.to_s, nil) || proposed_label
  end
end
