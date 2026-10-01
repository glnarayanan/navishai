class AssumptionImpact < ApplicationRecord
  belongs_to :workspace
  belongs_to :corpus
  belongs_to :source
  belongs_to :before_snapshot, class_name: "SourceSnapshot"
  belongs_to :after_snapshot, class_name: "SourceSnapshot"
  belongs_to :source_head, class_name: "SourceSnapshot"
  belongs_to :requested_by, class_name: "User"
  has_many :assumption_impact_inputs
  has_many :scenario_versions, through: :assumption_impact_inputs
  has_one :assumption_impact_result
  attr_readonly :workspace_id, :corpus_id, :source_id, :before_snapshot_id, :after_snapshot_id,
    :source_head_id, :requested_by_id, :historical, :input, :input_digest, :configuration,
    :request_digest, :processing_version, :request_key, :created_at
  validates :state, inclusion: { in: %w[queued running complete interrupted] }

  def self.request!(corpus:, membership:, source_id:, before_snapshot_id:, after_snapshot_id:, version_ids:, configuration:, input_digest:, disclose: false, historical: false)
    corpus.with_lock do
      corpus.authorize_writer!(membership)
      raise CorpusIntake::Invalid, "Confirm disclosure of the exact documents and scenario assumptions before requesting change analysis." unless disclose == true
      raise CorpusIntake::Invalid, "Use endpoint, model and fixed settings; never enter credentials." unless ModelGateway.valid_configuration?(configuration)
      input = AssumptionChangeAnalysis.preview(corpus:, source_id:, before_snapshot_id:, after_snapshot_id:, version_ids:)
      raise CorpusIntake::Invalid, "The preview changed. Review it again and confirm fresh disclosure." unless AssumptionChangeAnalysis.digest(input) == input_digest
      if input.fetch("historical") && historical != true
        raise CorpusIntake::Invalid, "Confirm that this historical comparison is intentional; it does not describe current policy."
      end
      AssumptionChangeAnalysis.check_payload!(input, configuration)
      EvaluationHttp.validate!(configuration.slice("endpoint"), workspace_id: corpus.workspace_id, purpose: :corpus)
      request_digest = AssumptionChangeAnalysis.digest({ "input" => input, "configuration" => configuration, "protocol" => AssumptionChangeAnalysis::VERSION })
      existing = where(corpus:).find_by(request_digest:)
      return existing if existing

      impact = create!(workspace: corpus.workspace, corpus:, source_id: input.fetch("source_id"),
        before_snapshot_id: input.dig("before", "snapshot_id"), after_snapshot_id: input.dig("after", "snapshot_id"),
        source_head_id: input.fetch("source_head_id"), requested_by: membership.user, historical: input.fetch("historical"),
        input:, input_digest:, configuration:, request_digest:, processing_version: AssumptionChangeAnalysis::VERSION, created_at: Time.current)
      input.fetch("scenarios").each do |entry|
        impact.assumption_impact_inputs.create!(workspace: corpus.workspace, corpus:, scenario_version_id: entry.fetch("version_id"))
      end
      AuditEvent.record!(action: "assumption_impact.requested", source: :web, workspace: corpus.workspace, actor: membership.user, subject: impact)
      AssumptionImpactJob.perform_later(impact.id)
      impact
    end
  end

  def expired?
    corpus.eval_definitions_expired?
  end

  def authorize_processing!
    reload
    return false unless state == "running"
    membership = workspace.memberships.find_by!(user: requested_by)
    corpus.authorize_writer!(membership)
    raise CorpusIntake::Invalid, "Unsupported change-analysis protocol or settings." unless processing_version == AssumptionChangeAnalysis::VERSION && ModelGateway.valid_configuration?(configuration)
    raise CorpusIntake::Invalid, "A newer document change arrived; review a new preview." unless source.reload.current_snapshot_id == source_head_id
    ids = assumption_impact_inputs.order(:scenario_version_id).pluck(:scenario_version_id)
    current = AssumptionChangeAnalysis.preview(corpus:, source_id:, before_snapshot_id:, after_snapshot_id:, version_ids: ids)
    raise CorpusIntake::Invalid, "Fixed assumptions or document inputs changed; no proposals retained." unless ids == input.fetch("scenarios").pluck("version_id") && AssumptionChangeAnalysis.digest(current) == input_digest
    AssumptionChangeAnalysis.check_payload!(input, configuration)
    EvaluationHttp.validate!(configuration.slice("endpoint"), workspace_id:, purpose: :corpus)
    true
  end

  def interrupt!(membership:)
    corpus.with_lock do
      corpus.authorize_writer!(membership)
      lock!
      raise ActiveRecord::RecordNotFound if expired?
      unless state == "queued" || (state == "running" && started_at < 10.minutes.ago)
        raise CorpusIntake::Invalid, "Only queued or over-ten-minute running attempts can be interrupted."
      end
      update!(state: "interrupted", finished_at: Time.current, error: "Expert interrupted this attempt. Remote outcome/cost may be unknown. It will not retry.")
      AuditEvent.record!(action: "assumption_impact.interrupted", source: :web, workspace:, actor: membership.user, subject: self)
    end
  end
end
