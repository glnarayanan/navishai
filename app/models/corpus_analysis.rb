class CorpusAnalysis < ApplicationRecord
  METHOD = "tfidf-seed-centroid-selection-v1"
  MAX_ITEMS = 2_000
  belongs_to :workspace
  belongs_to :corpus
  belongs_to :requested_by, class_name: "User"
  has_many :corpus_analysis_inputs
  has_many :corpus_items, through: :corpus_analysis_inputs
  has_many :issue_clusters
  has_many :taxonomy_versions
  validates :state, inclusion: { in: %w[queued complete failed] }
  validates :scenario_limit, numericality: { only_integer: true, in: 1..100 }

  def self.request!(corpus:, membership:, scenario_limit:)
    corpus.with_lock do
      corpus.authorize_writer!(membership)
      raise CorpusIntake::Invalid, "This baseline analyses at most 10 MiB of source text. Use a smaller corpus." if corpus.current_items.sum("octet_length(content)") > 10.megabytes
      items = corpus.current_items.order(:id).limit(MAX_ITEMS + 1).to_a
      raise CorpusIntake::Invalid, "Analysis needs 1–2000 current records. Use a smaller corpus for this local baseline." unless items.size.between?(1, MAX_ITEMS)
      analysis = corpus.corpus_analyses.create!(workspace: corpus.workspace, requested_by: membership.user, processing_method: METHOD, scenario_limit:)
      items.each { |item| analysis.corpus_analysis_inputs.create!(workspace: corpus.workspace, corpus:, corpus_item: item) }
      CorpusAnalysisJob.perform_later(analysis.id)
      analysis
    end
  end

  def latest_taxonomy
    taxonomy_versions.order(number: :desc).first
  end

  def expired?
    corpus_items.joins(source_snapshot: :source).where("sources.expires_at <= ?", Time.current).exists?
  end
end
