class Source < ApplicationRecord
  belongs_to :workspace
  belongs_to :corpus
  belongs_to :current_snapshot, class_name: "SourceSnapshot", optional: true
  has_many :source_snapshots
  validates :name, presence: true, length: { maximum: 180 }, uniqueness: { scope: [ :corpus_id, :kind ] }
  validates :kind, inclusion: { in: %w[conversations document traces] }
  validates :expires_at, presence: true

  def dependent_versions(snapshot: nil)
    snapshots = source_snapshots.where(corpus_id: corpus_id, workspace_id: workspace_id)
    snapshot_ids = snapshot ? snapshots.find(snapshot.id).id : snapshots.select(:id)
    versions = ScenarioVersion.where(corpus_id: corpus_id, workspace_id: workspace_id)
    return versions.none if corpus.eval_definitions_expired?

    versions.joins(scenario_evidence: :corpus_item)
      .where(corpus_items: { source_snapshot_id: snapshot_ids, corpus_id: corpus_id })
      .distinct
  end
end
