class HealthScorecard < ApplicationRecord
  belongs_to :workspace
  belongs_to :current_version, class_name: "HealthScorecardVersion", optional: true
  has_many :versions, -> { order(version_number: :desc) }, class_name: "HealthScorecardVersion",
    dependent: :restrict_with_exception
  has_many :design_turns, class_name: "HealthScorecardDesignTurn", dependent: :restrict_with_exception
  has_many :proposals, -> { order(created_at: :desc, id: :desc) }, class_name: "HealthScorecardProposal",
    dependent: :restrict_with_exception
  has_many :crew_tasks, dependent: :restrict_with_exception

  validates :name, presence: true, length: { maximum: 100 }
end
