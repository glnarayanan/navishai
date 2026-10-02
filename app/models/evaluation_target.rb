class EvaluationTarget < ApplicationRecord
  belongs_to :workspace
  belongs_to :corpus
  belongs_to :current_version, class_name: "EvaluationTargetVersion", optional: true
  has_many :evaluation_target_versions
  validates :name, presence: true, length: { maximum: 120 }

  def self.define!(corpus:, membership:, name:, configuration:, adapter: "scripted")
    corpus.with_lock do
      corpus.authorize_writer!(membership, manage: true)
      target = corpus.evaluation_targets.create!(workspace: corpus.workspace, name:)
      target.revise!(membership:, version_id: nil, configuration:, adapter:)
      target
    end
  end

  def revise!(membership:, version_id:, configuration:, adapter: nil)
    corpus.with_lock do
      corpus.authorize_writer!(membership, manage: true)
      raise EvalCase::Invalid, "Source retention ended. Wait for purge before defining a target." if corpus.eval_definitions_expired?
      reload
      raise EvalCase::Invalid, "This target changed. Reload before saving." unless current_version_id.to_s == version_id.to_s
      adapter ||= current_version&.adapter || "scripted"
      raise EvalCase::Invalid, "Choose the scripted or HTTP adapter." unless %w[scripted http].include?(adapter)
      return current_version if current_version && current_version.configuration == configuration && current_version.adapter == adapter
      processing_version = adapter == "http" ? HttpTarget::VERSION : ScriptedTarget::VERSION
      version = evaluation_target_versions.create!(workspace:, corpus:, created_by: membership.user, number: (current_version&.number || 0) + 1, adapter:, processing_version:, configuration:, created_at: Time.current)
      update!(current_version: version)
      AuditEvent.record!(action: "target.version_created", source: :web, workspace:, actor: membership.user, subject: version, metadata: { version: version.number })
      version
    end
  end
end
