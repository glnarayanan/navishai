class ClusterMember < ImmutableRecord
  belongs_to :workspace
  belongs_to :corpus
  belongs_to :issue_cluster
  belongs_to :corpus_item
  scope :selected, -> { where.not(selection_reason: nil) }

  # Keep each source lookup indexed even after purge leaves empty-table statistics.
  # OFFSET 0 prevents PostgreSQL from flattening this into an unparameterized join.
  scope :with_corpus_item, -> {
    joins(<<~SQL.squish)
      INNER JOIN LATERAL (
        SELECT * FROM corpus_items
        WHERE corpus_items.workspace_id = cluster_members.workspace_id
          AND corpus_items.corpus_id = cluster_members.corpus_id
          AND corpus_items.id = cluster_members.corpus_item_id OFFSET 0
      ) corpus_items ON true
    SQL
  }
end
