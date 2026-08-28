class Account < ApplicationRecord
  belongs_to :workspace

  has_many :contacts, dependent: :restrict_with_exception
  has_many :crew_tasks, dependent: :restrict_with_exception
  has_many :health_inputs, class_name: "AccountHealthInput", dependent: :restrict_with_exception
  has_many :health_assessments, -> { order(calculated_at: :desc, id: :desc) },
    class_name: "AccountHealthAssessment", dependent: :restrict_with_exception
  has_many :risk_investigations, class_name: "AccountRiskInvestigation", dependent: :restrict_with_exception
  has_many :customer_success_interventions, dependent: :restrict_with_exception
  has_many :source_identities, dependent: :restrict_with_exception
  has_many :source_merges, class_name: "AccountMerge", foreign_key: :source_id, dependent: :restrict_with_exception
  has_many :target_merges, class_name: "AccountMerge", foreign_key: :target_id, dependent: :restrict_with_exception

  normalizes :name, with: ->(name) { name.strip }

  validates :name, presence: true, length: { maximum: 200 }

  def canonical
    merge = if source_merges.loaded?
      source_merges.find { |candidate| candidate.unmerged_at.nil? }
    else
      source_merges.active.first
    end
    merge&.target&.canonical || self
  end

  def current_health_assessment
    health_assessments.first
  end
end
