class AccountHealthAssessment < ApplicationRecord
  RISK_LEVELS = %w[healthy watch at_risk].freeze
  TRIGGER_KINDS = %w[input_change schedule renewal_window human_request].freeze

  belongs_to :workspace
  belongs_to :account
  belongs_to :health_scorecard_version
  belongs_to :previous_assessment, class_name: "AccountHealthAssessment", optional: true
  has_many :signals, -> { order(:id) }, class_name: "AccountHealthSignal", dependent: :restrict_with_exception
  has_one :risk_investigation, class_name: "AccountRiskInvestigation", dependent: :restrict_with_exception
  has_many :originating_customer_success_interventions, class_name: "CustomerSuccessIntervention",
    dependent: :restrict_with_exception
  has_many :before_intervention_outcome_reviews, class_name: "CustomerSuccessInterventionOutcomeReview",
    foreign_key: :before_account_health_assessment_id, dependent: :restrict_with_exception,
    inverse_of: :before_account_health_assessment
  has_many :after_intervention_outcome_reviews, class_name: "CustomerSuccessInterventionOutcomeReview",
    foreign_key: :after_account_health_assessment_id, dependent: :restrict_with_exception,
    inverse_of: :after_account_health_assessment

  validates :score, numericality: { only_integer: true, in: 0..100 }
  validates :risk_level, inclusion: { in: RISK_LEVELS }
  validates :trigger_kind, inclusion: { in: TRIGGER_KINDS }
  validates :calculated_at, presence: true

  def readonly? = persisted?
end
