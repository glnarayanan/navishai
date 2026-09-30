class Grader < ApplicationRecord
  belongs_to :workspace
  belongs_to :corpus
  belongs_to :current_version, class_name: "GraderVersion", optional: true
  has_many :grader_versions
  validates :name, presence: true, length: { maximum: 120 }

  def self.define!(corpus:, membership:, name:, kind:, definition:)
    corpus.with_lock do
      corpus.authorize_writer!(membership)
      grader = corpus.graders.create!(workspace: corpus.workspace, name:)
      grader.revise!(membership:, version_id: nil, kind:, definition:)
      grader
    end
  end

  def revise!(membership:, version_id:, kind:, definition:)
    corpus.with_lock do
      corpus.authorize_writer!(membership)
      raise EvalCase::Invalid, "Source retention ended. Wait for source purge before creating new definitions." if corpus.eval_definitions_expired?
      reload
      raise EvalCase::Invalid, "This grader changed. Reload before saving." unless current_version_id.to_s == version_id.to_s
      return current_version if current_version && current_version.kind == kind && current_version.definition == definition

      version = grader_versions.create!(workspace:, corpus:, created_by: membership.user, number: (current_version&.number || 0) + 1, kind:,
        definition:, processing_version: kind == "deterministic" ? DeterministicGrader::VERSION : "rubric-judge-v1", created_at: Time.current)
      update!(current_version: version)
      AuditEvent.record!(action: "grader.version_created", source: :web, workspace:, actor: membership.user, subject: version, metadata: { version: version.number })
      version
    end
  end
end
