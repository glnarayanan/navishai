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
  has_one :corpus_analysis_result
  attr_readonly :workspace_id, :corpus_id, :requested_by_id, :processing_method, :scenario_limit, :configuration, :input_digest, :request_key, :created_at
  validates :state, inclusion: { in: %w[queued running complete failed] }
  validates :scenario_limit, numericality: { only_integer: true, in: 1..100 }

  def self.request!(corpus:, membership:, scenario_limit:, configuration: nil, disclose: false, input_digest: nil)
    corpus.with_lock do
      corpus.authorize_writer!(membership)
      model = !configuration.nil?
      items = current_inputs(corpus:, model:)
      if model
        raise CorpusIntake::Invalid, "The prior request did not start. Confirm disclosure of the exact corpus preview before model discovery." unless disclose == true
        raise CorpusIntake::Invalid, "Use endpoint, model and fixed settings; never include credentials." unless ModelGateway.valid_configuration?(configuration)
        raise CorpusIntake::Invalid, "Model discovery accepts 1–20 candidates." unless scenario_limit.to_i.between?(1, ModelCorpusDiscovery::MAX_CANDIDATES)
        preview = ModelCorpusDiscovery.input(items)
        raise CorpusIntake::Invalid, "The corpus preview changed. Reload and confirm the current records before model discovery." unless ModelCorpusDiscovery.digest(preview) == input_digest
        EvaluationHttp.validate!(configuration.slice("endpoint"), workspace_id: corpus.workspace_id, purpose: :corpus)
      end
      analysis = corpus.corpus_analyses.create!(workspace: corpus.workspace, requested_by: membership.user,
        processing_method: model ? ModelCorpusDiscovery::VERSION : METHOD, configuration: model ? configuration : {}, input_digest: model ? input_digest : nil, scenario_limit:)
      items.each { |item| analysis.corpus_analysis_inputs.create!(workspace: corpus.workspace, corpus:, corpus_item: item) }
      AuditEvent.record!(action: "corpus.analysis_requested", source: :web, workspace: corpus.workspace, actor: membership.user, subject: analysis)
      CorpusAnalysisJob.perform_later(analysis.id)
      analysis
    end
  end

  def self.current_inputs(corpus:, model: false)
    inputs = corpus.current_items.where(sources: { kind: %w[conversations document] })
    raise CorpusIntake::Invalid, "Local analysis accepts at most 10 MiB of source text. Use a smaller corpus." if !model && inputs.sum("octet_length(content)") > 10.megabytes
    limit = model ? ModelCorpusDiscovery::MAX_ITEMS : MAX_ITEMS
    items = inputs.includes(source_snapshot: :source).order(:id).limit(limit + 1).to_a
    raise CorpusIntake::Invalid, "Analysis needs 1–#{limit} current conversation/document records. Production traces use separate review." unless items.size.between?(1, limit)
    items
  end

  def model?
    processing_method == ModelCorpusDiscovery::VERSION
  end

  def interrupt!(membership:)
    corpus.with_lock do
      corpus.authorize_writer!(membership)
      lock!
      raise CorpusIntake::Invalid, "Only queued analyses or attempts started over ten minutes ago can be interrupted." unless state == "queued" || (state == "running" && started_at < 10.minutes.ago)
      update!(state: "failed", finished_at: Time.current, error: "Expert interrupted this attempt. Remote outcome/cost may be unknown; request a new analysis deliberately. No automatic retry.")
      AuditEvent.record!(action: "corpus.analysis_interrupted", source: :web, workspace:, actor: membership.user, subject: self)
    end
  end

  def latest_taxonomy
    taxonomy_versions.order(number: :desc).first
  end

  def expired?
    corpus_items.joins(source_snapshot: :source).where("sources.expires_at <= ?", Time.current).exists?
  end

  def stale?
    corpus_items.joins(source_snapshot: :source).where(sources: { kind: "document" }).where("sources.current_snapshot_id <> source_snapshots.id").exists?
  end
end
