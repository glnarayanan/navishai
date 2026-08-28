class AccountRiskInvestigation < ApplicationRecord
  STATUSES = %w[detected investigating resolved].freeze
  TRIGGER_KINDS = %w[material_change renewal_window human_request].freeze

  belongs_to :workspace
  belongs_to :account
  belongs_to :account_health_assessment
  belongs_to :crew_task, optional: true
  has_many :customer_success_interventions, dependent: :restrict_with_exception

  enum :status, STATUSES.index_by(&:itself), validate: true
  validates :trigger_kind, inclusion: { in: TRIGGER_KINDS }
  validates :opened_at, presence: true
  validate :records_share_account

  private
    def records_share_account
      errors.add(:account_health_assessment, "belongs to another account") if account_health_assessment && account_health_assessment.account_id != account_id
      errors.add(:crew_task, "belongs to another account") if crew_task && crew_task.account_id != account_id
    end
end
