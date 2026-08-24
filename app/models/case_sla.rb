class CaseSla < ApplicationRecord
  STATUSES = %w[pending met breached].freeze

  belongs_to :workspace
  belongs_to :support_case
  belongs_to :sla_policy
  has_many :escalation_tasks, class_name: "SlaEscalationTask", dependent: :restrict_with_exception

  enum :first_response_status, STATUSES.index_by(&:itself), prefix: :first_response, validate: true
  enum :resolution_status, STATUSES.index_by(&:itself), prefix: :resolution, validate: true

  validates :started_at, :first_response_warning_at, :first_response_due_at,
    :resolution_warning_at, :resolution_due_at, presence: true
  validates :paused_business_seconds, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate :records_belong_to_workspace

  private
    def records_belong_to_workspace
      errors.add(:support_case, "belongs to another workspace") if support_case && support_case.workspace_id != workspace_id
      errors.add(:sla_policy, "belongs to another workspace") if sla_policy && sla_policy.workspace_id != workspace_id
    end
end
