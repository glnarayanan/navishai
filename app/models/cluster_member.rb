class ClusterMember < ImmutableRecord
  belongs_to :workspace
  belongs_to :corpus
  belongs_to :issue_cluster
  belongs_to :corpus_item
  scope :selected, -> { where.not(selection_reason: nil) }
end
