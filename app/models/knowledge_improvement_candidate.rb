class KnowledgeImprovementCandidate < ApplicationRecord
  STATUSES = %w[open triaged assigned resolved dismissed].freeze
  REASON_CODES = %w[missing_knowledge stale deleted retired failed_sync].freeze
  REASON_LABELS = {
    "missing_knowledge" => "Missing knowledge",
    "stale" => "Stale source",
    "deleted" => "Deleted source",
    "retired" => "Retired source",
    "failed_sync" => "Failed sync"
  }.freeze

  belongs_to :workspace
  belongs_to :source_crew_artifact, class_name: "CrewArtifact", optional: true
  belongs_to :support_case, optional: true
  belongs_to :knowledge_source, optional: true
  belongs_to :created_by_membership, class_name: "Membership"
  belongs_to :triaged_by_membership, class_name: "Membership", optional: true
  belongs_to :assigned_to_membership, class_name: "Membership", optional: true
  belongs_to :assigned_by_membership, class_name: "Membership", optional: true
  belongs_to :resolved_knowledge_source, class_name: "KnowledgeSource", optional: true
  belongs_to :resolved_knowledge_source_version, class_name: "KnowledgeSourceVersion", optional: true
  belongs_to :resolved_by_membership, class_name: "Membership", optional: true
  belongs_to :dismissed_by_membership, class_name: "Membership", optional: true

  enum :status, STATUSES.index_by(&:itself), validate: true
  enum :reason_code, REASON_CODES.index_by(&:itself), validate: true

  scope :open_work, -> { where(status: %w[open triaged assigned]) }
  scope :recently_resolved, -> { where(status: "resolved").order(resolved_at: :desc, id: :desc) }

  def reason_label
    REASON_LABELS.fetch(reason_code)
  end

  def open_work?
    open? || triaged? || assigned?
  end
end
