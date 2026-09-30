class EvaluationTarget < ApplicationRecord
  belongs_to :workspace
  belongs_to :corpus
  belongs_to :current_version, class_name: "EvaluationTargetVersion", optional: true
  has_many :evaluation_target_versions
  validates :name, presence: true, length: { maximum: 120 }

  def self.define!(corpus:, membership:, name:, configuration:, adapter: "scripted", trace_item_id: nil)
    corpus.with_lock do
      corpus.authorize_writer!(membership, manage: true)
      target = corpus.evaluation_targets.create!(workspace: corpus.workspace, name:)
      target.revise!(membership:, version_id: nil, configuration:, adapter:, trace_item_id:)
      target
    end
  end

  def revise!(membership:, version_id:, configuration:, adapter: nil, trace_item_id: nil)
    corpus.with_lock do
      corpus.authorize_writer!(membership, manage: true)
      raise EvalCase::Invalid, "Source retention ended. Wait for purge before defining a target." if corpus.eval_definitions_expired?
      reload
      raise EvalCase::Invalid, "This target changed. Reload before saving." unless current_version_id.to_s == version_id.to_s
      adapter ||= current_version&.adapter || "scripted"
      raise EvalCase::Invalid, "Choose the scripted, HTTP or recorded adapter." unless %w[scripted http recorded].include?(adapter)
      trace_item = corpus.corpus_items.find_by(id: trace_item_id) if adapter == "recorded"
      RecordedTarget.validate!(trace_item:) if adapter == "recorded"
      return current_version if current_version && current_version.configuration == configuration && current_version.adapter == adapter && current_version.trace_item_id == trace_item&.id
      processing_version = { "http" => HttpTarget::VERSION, "scripted" => ScriptedTarget::VERSION, "recorded" => RecordedTarget::VERSION }.fetch(adapter)
      version = evaluation_target_versions.create!(workspace:, corpus:, created_by: membership.user, number: (current_version&.number || 0) + 1, adapter:, processing_version:, configuration:, trace_item:, created_at: Time.current)
      update!(current_version: version)
      AuditEvent.record!(action: "target.version_created", source: :web, workspace:, actor: membership.user, subject: version, metadata: { version: version.number })
      version
    end
  end
end
