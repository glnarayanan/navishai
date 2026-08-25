class HealthScorecardVersion < ApplicationRecord
  belongs_to :workspace
  belongs_to :health_scorecard
  belongs_to :created_by_membership, class_name: "Membership", optional: true
  belongs_to :created_by_user, class_name: "User", optional: true
  has_many :design_turns, class_name: "HealthScorecardDesignTurn", dependent: :restrict_with_exception
  has_many :backtests, -> { order(created_at: :desc, id: :desc) },
    class_name: "HealthScorecardBacktest", dependent: :restrict_with_exception
  has_many :health_assessments, class_name: "AccountHealthAssessment", dependent: :restrict_with_exception

  validates :version_number, numericality: { only_integer: true, greater_than: 0 }
  validates :design_prompt, length: { in: 1..4_000 }
  validates :explanation, length: { in: 1..8_000 }
  validate :definition_is_valid

  def readonly? = persisted?

  def published? = health_scorecard.current_version_id == id

  private
    def definition_is_valid
      HealthScorecardDefinition.validate!(definition)
    rescue HealthScorecardDefinition::InvalidDefinition => error
      errors.add(:definition, error.message)
    end
end
