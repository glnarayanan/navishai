class HealthScorecardDesignTurn < ApplicationRecord
  belongs_to :workspace
  belongs_to :health_scorecard
  belongs_to :health_scorecard_version
  belongs_to :membership
  belongs_to :user

  validates :prompt, length: { in: 1..4_000 }
  validates :response, length: { in: 1..8_000 }

  def readonly? = persisted?
end
