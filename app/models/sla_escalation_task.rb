class SlaEscalationTask < ApplicationRecord
  OBJECTIVES = %w[first_response resolution].freeze
  KINDS = %w[warning breach].freeze
  STATUSES = %w[open completed].freeze

  belongs_to :workspace
  belongs_to :case_sla

  enum :objective, OBJECTIVES.index_by(&:itself), validate: true
  enum :kind, KINDS.index_by(&:itself), validate: true
  enum :status, STATUSES.index_by(&:itself), validate: true

  validates :occurred_at, presence: true
  validates :kind, uniqueness: { scope: [ :case_sla_id, :objective ] }
  validate :case_sla_belongs_to_workspace

  private
    def case_sla_belongs_to_workspace
      errors.add(:case_sla, "belongs to another workspace") if case_sla && case_sla.workspace_id != workspace_id
    end
end
