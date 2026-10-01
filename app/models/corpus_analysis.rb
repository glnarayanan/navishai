class CorpusAnalysis < ApplicationRecord
  METHOD = "tfidf-seed-centroid-selection-v1"
  MAX_ITEMS = 2_000
  MAX_RECORD_BYTES = 10.megabytes
  belongs_to :workspace
  belongs_to :corpus
  belongs_to :requested_by, class_name: "User"
  has_many :corpus_analysis_inputs
  has_many :corpus_items, through: :corpus_analysis_inputs
  has_many :issue_clusters
  has_many :taxonomy_versions
  has_one :corpus_analysis_result
  has_many :corpus_discovery_batches
  attr_readonly :workspace_id, :corpus_id, :requested_by_id, :processing_method, :scenario_limit, :configuration, :input_digest, :call_plan, :request_key, :created_at
  validates :state, inclusion: { in: %w[queued running complete failed] }
  validates :scenario_limit, numericality: { only_integer: true, in: 1..100 }

  def self.request!(corpus:, membership:, scenario_limit:, configuration: nil, disclose: false, input_digest: nil, processing_method: nil, call_plan_digest: nil)
    corpus.with_lock do
      corpus.authorize_writer!(membership)
      model = !configuration.nil?
      batch = processing_method == "model_batch"
      raise CorpusIntake::Invalid, "Batch discovery requires fixed model settings." if batch && !model
      items = current_inputs(corpus:, model:, batch:)
      plan = batch ? BatchCorpusDiscovery.plan(items) : {}
      if model
        raise CorpusIntake::Invalid, "The prior request did not start. Confirm disclosure of the exact corpus preview before model discovery." unless disclose == true
        raise CorpusIntake::Invalid, "Use endpoint, model and fixed settings; never include credentials." unless ModelGateway.valid_configuration?(configuration)
        raise CorpusIntake::Invalid, "Model discovery accepts 1–20 candidates." unless scenario_limit.to_i.between?(1, ModelCorpusDiscovery::MAX_CANDIDATES)
        preview = ModelCorpusDiscovery.input(items, bounded: !batch)
        raise CorpusIntake::Invalid, "The corpus preview changed. Reload and confirm the current records before model discovery." unless ModelCorpusDiscovery.digest(preview) == input_digest
        raise CorpusIntake::Invalid, "The call plan changed. Reload and confirm the exact allocation." if batch && ModelCorpusDiscovery.digest(plan) != call_plan_digest
        EvaluationHttp.validate!(configuration.slice("endpoint"), workspace_id: corpus.workspace_id, purpose: :corpus)
      end
      analysis = corpus.corpus_analyses.create!(workspace: corpus.workspace, requested_by: membership.user,
        processing_method: batch ? BatchCorpusDiscovery::VERSION : (model ? ModelCorpusDiscovery::VERSION : METHOD), configuration: model ? configuration : {}, input_digest: model ? input_digest : nil, call_plan: plan, scenario_limit:)
      items.each { |item| analysis.corpus_analysis_inputs.create!(workspace: corpus.workspace, corpus:, corpus_item: item) }
      if batch
        plan.fetch("batches").each do |definition|
          analysis.corpus_discovery_batches.create!(workspace: corpus.workspace, corpus:, **definition.except("bytes").symbolize_keys, created_at: Time.current)
        end
        if plan.fetch("reducer")
          refs = analysis.corpus_discovery_batches.order(:position).pluck(:request_key).map(&:to_s)
          analysis.corpus_discovery_batches.create!(workspace: corpus.workspace, corpus:, phase: "reducer", position: refs.size + 1,
            input_refs: refs, input_digest: ModelCorpusDiscovery.digest(plan.fetch("batches").pluck("input_digest")), created_at: Time.current)
        end
      end
      AuditEvent.record!(action: "corpus.analysis_requested", source: :web, workspace: corpus.workspace, actor: membership.user, subject: analysis)
      CorpusAnalysisJob.perform_later(analysis.id)
      analysis
    end
  end

  def self.current_inputs(corpus:, model: false, batch: false)
    corpus.with_lock do
      inputs = corpus.current_items.where(sources: { kind: %w[conversations document] }).order(:id)
      load_inputs(inputs, limit: model && !batch ? ModelCorpusDiscovery::MAX_ITEMS : MAX_ITEMS)
    end
  end

  def fixed_inputs
    corpus.with_lock do
      raise CorpusIntake::Invalid, "Source inputs expired; request a new analysis." if expired?
      inputs = corpus_items.order(model? ? :id : [ :external_id, :id ])
      self.class.load_inputs(inputs, limit: model? && !batch? ? ModelCorpusDiscovery::MAX_ITEMS : MAX_ITEMS)
    end
  end

  # Call under the corpus lock so intake/purge cannot change membership between
  # aggregate checks and loading. Encoded model/per-call bounds still apply later.
  def self.load_inputs(inputs, limit:)
    raise CorpusIntake::Invalid, "Analysis needs 1–#{limit} conversation/document records. Production traces use separate review." unless inputs.count.between?(1, limit)
    bytes = inputs.sum("octet_length(corpus_items.external_id) + octet_length(corpus_items.title) + octet_length(corpus_items.content) + octet_length(corpus_items.context::text)")
    raise CorpusIntake::Invalid, "Analysis accepts at most 10 MiB of retained IDs, titles, text and context JSON. Use a smaller corpus; nothing is sampled or truncated." if bytes > MAX_RECORD_BYTES
    inputs.includes(source_snapshot: :source).to_a
  end

  def model?
    processing_method.in?([ ModelCorpusDiscovery::VERSION, BatchCorpusDiscovery::VERSION ])
  end

  def batch?
    processing_method == BatchCorpusDiscovery::VERSION
  end

  # The job and each batch use this under a short corpus lock, never over transport.
  def authorize_processing!
    reload
    return false unless state == "running"
    membership = workspace.memberships.find_by!(user: requested_by)
    corpus.authorize_writer!(membership)
    raise CorpusIntake::Invalid, "Source inputs expired; request a new analysis." if expired?
    items = fixed_inputs
    if model?
      raise CorpusIntake::Invalid, "Company documentation changed; request a new analysis using current evidence." if stale?
      raise CorpusIntake::Invalid, "Invalid fixed model settings." unless ModelGateway.valid_configuration?(configuration)
      input = ModelCorpusDiscovery.input(items, bounded: !batch?)
      raise CorpusIntake::Invalid, "Fixed corpus inputs changed; no proposals saved." unless ModelCorpusDiscovery.digest(input) == input_digest
      raise CorpusIntake::Invalid, "Fixed call plan changed." if batch? && BatchCorpusDiscovery.plan(items) != call_plan
      EvaluationHttp.validate!(configuration.slice("endpoint"), workspace_id:, purpose: :corpus)
    else
      raise CorpusIntake::Invalid, "Unsupported discovery method." unless processing_method == METHOD
    end
    true
  end

  def interrupt!(membership:)
    corpus.with_lock do
      corpus.authorize_writer!(membership)
      lock!
      raise CorpusIntake::Invalid, "Only queued analyses or attempts started over ten minutes ago can be interrupted." unless state == "queued" || (state == "running" && (batch? || started_at < 10.minutes.ago))
      update!(state: "failed", finished_at: Time.current, error: "Expert interrupted this attempt. Remote outcome/cost may be unknown; request a new analysis deliberately. No automatic retry.")
      AuditEvent.record!(action: "corpus.analysis_interrupted", source: :web, workspace:, actor: membership.user, subject: self)
    end
  end

  def latest_taxonomy
    taxonomy_versions.order(number: :desc).first
  end

  def selection_groups
    selected_ids = ClusterMember.selected.where(issue_cluster: issue_clusters).select(:issue_cluster_id)
    { "All families" => issue_clusters, "With selected candidates" => issue_clusters.where(id: selected_ids),
      "No selected candidates" => issue_clusters.where.not(id: selected_ids) }
  end

  def expired?
    corpus_items.joins(source_snapshot: :source).where("sources.expires_at <= ?", Time.current).exists?
  end

  def stale?
    corpus_items.joins(source_snapshot: :source).where(sources: { kind: "document" }).where("sources.current_snapshot_id <> source_snapshots.id").exists?
  end
end
