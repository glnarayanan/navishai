class TaxonomyVersion < ImmutableRecord
  belongs_to :workspace
  belongs_to :corpus
  belongs_to :corpus_analysis
  belongs_to :reviewed_by, class_name: "User"
  validates :number, numericality: { only_integer: true, greater_than: 0 }

  def self.review!(analysis:, membership:, cluster_id:, label:)
    analysis.corpus.with_lock do
      analysis.corpus.authorize_writer!(membership)
      raise CorpusIntake::Invalid, "Source inputs expired; create a new analysis." if analysis.expired?
      cluster = analysis.issue_clusters.find(cluster_id)
      raise CorpusIntake::Invalid, "Use an issue label of 1–120 characters." unless label.is_a?(String) && label.strip.length.between?(1, 120)
      previous = analysis.latest_taxonomy
      version = analysis.taxonomy_versions.create!(workspace: analysis.workspace, corpus: analysis.corpus,
        reviewed_by: membership.user, number: (previous&.number || 0) + 1,
        labels: (previous&.labels || {}).merge(cluster.id.to_s => label.strip), created_at: Time.current)
      AuditEvent.record!(action: "taxonomy.reviewed", source: :web, workspace: analysis.workspace,
        actor: membership.user, subject: version, metadata: { version: version.number })
      version
    end
  end
end
