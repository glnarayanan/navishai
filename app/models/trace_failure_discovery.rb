class TraceFailureDiscovery < ApplicationRecord
  belongs_to :workspace
  belongs_to :corpus
  belongs_to :requested_by, class_name: "User"
  has_many :trace_failure_discovery_inputs
  has_many :corpus_items, through: :trace_failure_discovery_inputs
  has_many :trace_failure_discovery_versions
  has_many :scenario_versions, through: :trace_failure_discovery_versions
  has_many :trace_failure_discovery_cases
  has_many :eval_cases, through: :trace_failure_discovery_cases
  has_many :trace_failure_reviews
  has_one :trace_failure_discovery_result
  attr_readonly :workspace_id, :corpus_id, :requested_by_id, :configuration, :input_content, :input_digest, :processing_version, :request_key, :created_at
  validates :state, inclusion: { in: %w[queued running complete interrupted] }

  def self.request!(corpus:, membership:, configuration:, disclose:, input_digest:)
    corpus.with_lock do
      corpus.authorize_writer!(membership)
      raise CorpusIntake::Invalid, "Confirm the exact contents and trace failure discovery purpose before disclosure. No request started." unless disclose == true
      raise CorpusIntake::Invalid, "Use endpoint, model and fixed settings; never include credentials." unless ModelGateway.valid_configuration?(configuration)
      preview = TraceFailureDiscoveryPreview.current(corpus)
      raise CorpusIntake::Invalid, "The preview changed. Reload and confirm all current contents again. No request started." unless TraceFailureDiscoveryPreview.digest(preview.fetch(:input)) == input_digest
      EvaluationHttp.validate!(configuration.slice("endpoint"), workspace_id: corpus.workspace_id, purpose: :corpus)
      discovery = create!(workspace: corpus.workspace, corpus:, requested_by: membership.user, configuration:, input_content: preview.fetch(:input), input_digest:,
        processing_version: TraceFailureDiscoveryProtocol::VERSION, created_at: Time.current)
      { trace_failure_discovery_inputs: [ preview.fetch(:items), :corpus_item ], trace_failure_discovery_versions: [ preview.fetch(:versions), :scenario_version ],
        trace_failure_discovery_cases: [ preview.fetch(:cases), :eval_case ] }.each do |association, (records, key)|
        records.each { |record| discovery.public_send(association).create!(workspace: corpus.workspace, corpus:, key => record) }
      end
      AuditEvent.record!(action: "trace.discovery_requested", source: :web, workspace: corpus.workspace, actor: membership.user, subject: discovery)
      TraceFailureDiscoveryJob.perform_later(discovery.id)
      discovery
    end
  end

  def expired?
    corpus.eval_definitions_expired? || corpus_items.joins(source_snapshot: :source).where("sources.expires_at <= ?", Time.current).exists?
  end

  def stale?
    corpus_items.joins(source_snapshot: :source).where(sources: { kind: "document" }).where("sources.current_snapshot_id <> source_snapshots.id").exists? ||
      scenario_versions.joins(:scenario).where("scenarios.current_version_id <> scenario_versions.id OR scenarios.merged_into_id IS NOT NULL").exists?
  end

  def authorize_processing!
    reload
    return false unless state == "running"
    membership = workspace.memberships.find_by!(user: requested_by)
    corpus.authorize_writer!(membership)
    ensure_evidence!
    raise CorpusIntake::Invalid, "Unsupported discovery protocol or settings." unless processing_version == TraceFailureDiscoveryProtocol::VERSION && ModelGateway.valid_configuration?(configuration)
    EvaluationHttp.validate!(configuration.slice("endpoint"), workspace_id:, purpose: :corpus)
    true
  end

  def ensure_evidence!
    raise CorpusIntake::Invalid, "Source evidence expired; no discovery content is available." if expired?
    raise CorpusIntake::Invalid, "Company documents or case definitions changed. Request a new preview before processing or accepting findings." if stale?
    # New documents, scenarios, reviews and compilations change the disclosed comparison
    # set. A new trace export alone does not erase fixed historical trace evidence.
    current = TraceFailureDiscoveryPreview.fixed(self)
    raise CorpusIntake::Invalid, "The disclosed comparison set changed. Request a new preview." unless TraceFailureDiscoveryPreview.digest(current) == input_digest
  end

  def interrupt!(membership:)
    corpus.with_lock do
      corpus.authorize_writer!(membership)
      lock!
      raise CorpusIntake::Invalid, "Only queued attempts or attempts started over ten minutes ago can be interrupted." unless state == "queued" || (state == "running" && started_at < 10.minutes.ago)
      update!(state: "interrupted", finished_at: Time.current, error: "Expert interrupted this attempt. Remote outcome/cost may be unknown. No automatic retry; request a new preview deliberately.")
      AuditEvent.record!(action: "trace.discovery_interrupted", source: :web, workspace:, actor: membership.user, subject: self)
    end
  end
end
